# Case Study: PCalc (Mobile Scientific Calculator)

Authoritative case study and technical post-mortem for running PCalc on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: PCalc
- **Bundle Identifier**: `com.pcalc.mobile` (also legacy `com.tlao.pcalc`)
- **Tested Version**: 3.7.5 (Build 574)
- **Minimum iOS Version**: iOS 8.0
- **Engine / Architecture**: Native CocoaTouch / Objective-C & C
- **Graphics Backend**: UIKit / CoreGraphics
- **Audio Stack**: System Audio (`AudioToolbox`)
- **Window Profile**: Free / Aspect Unlocked, Resizable (`scale_mode = native`)

---

## 2. Контекст запуска и хронология

PCalc стал исторически первым приложением, на котором проводилась верификация базовой гипотезы проекта `ipa2mac` (шаги 39–83 диалога, коммит `bcdd7e5`). 

Задача заключалась в подтверждении фундаментального тезиса: не зашифрованный (`cryptid = 0`) 64-битный ARM64 бинарник iOS способен исполняться нативно на macOS (Apple Silicon M-серии) в режиме **Mac Catalyst** без процессорной эмуляции, если модифицировать заголовок `LC_BUILD_VERSION` и предоставить микро-шим для системных iOS API.

Позднее (шаг 3627) поведение окна PCalc потребовало повторной калибровки, когда глобальные оконные правила `mod_window.m` исказили естественные пропорции калькулятора.

---

## 3. Что вызывало баг (Root Cause)

При попытке прямого запуска расшифрованного iOS-бинарника на macOS возникли следующие блокирующие проблемы:

### 3.1. Блокировка Gatekeeper и AMFI (`SIGKILL (CODESIGN)`)
macOS на уровне ядра (AMFI) запрещает выполнение Mach-O бинарников с платформой `PLATFORM_IOS` (значение 2 в `LC_BUILD_VERSION`), помечая их как недействительные для подсистемы LaunchServices. Приложение моментально завершалось с кодом `SIGKILL (COREDUMP / CODESIGN)`.

### 3.2. Крах при обращении к Keychain (`errSecMissingEntitlement -34018`)
При первом запуске PCalc генерирует уникальный идентификатор установки и сохраняет пользовательские настройки (темы, раскладки клавиш) в iOS Keychain через вызовы `SecItemCopyMatching` и `SecItemAdd`. На Mac Catalyst доступ к связке ключей macOS требует обязательного entitlement `keychain-access-groups`. У ad-hoc подписанного бинарника этот entitlement отсутствует, в результате чего вызов возвращал ошибку `-34018` (`errSecMissingEntitlement`), приводя к аварийному завершению (`abort()`).

### 3.3. Искажение лейаута при принудительном масштабировании
Когда в шим была внедрена общая логика фиксации оконного соотношения сторон (16:9 / 3:4), интерфейс калькулятора сплющился по вертикали: кнопки стали овальными, лента расчетов обрезалась. PCalc изначально спроектирован под адаптивный UIKit-лейаут и требует свободного ресайзинга (`aspect_ratio = free`).

### 3.4. Зависание фонового процесса при закрытии окна
При нажатии на красную кнопку закрытия окна в macOS AppKit окно визуально скрывалось, однако процесс продолжал висеть в памяти (`NSWindowWillCloseNotification` не инициировал `terminate:`).

---

## 4. Что мы применили (Applied Solution)

### 4.1. Конвертация платформы в Mac Catalyst
```bash
# Переразметка платформы бинарника с iOS (2) на Mac Catalyst (6)
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output Payload/PCalc.app/PCalc Payload/PCalc.app/PCalc
```

### 4.2. In-Memory Keychain Shim (`core_keychain.c`)
Интерпозиция функций Security Framework в потокобезопасный in-memory словарь `CFMutableDictionaryRef` полностью изолировала приложение от системного демона `securityd`:

```c
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <pthread.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static CFMutableDictionaryRef s_keychain_dict = NULL;
static pthread_mutex_t s_keychain_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

static OSStatus shim_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    pthread_mutex_lock(&s_keychain_lock);
    if (!s_keychain_dict) s_keychain_dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    const void *key = CFDictionaryGetValue(attributes, kSecAttrAccount);
    if (!key) key = CFDictionaryGetValue(attributes, kSecAttrService);
    if (!key) key = CFSTR("default");

    const void *val = CFDictionaryGetValue(attributes, kSecValueData);
    if (!val) val = CFSTR("");

    CFDictionarySetValue(s_keychain_dict, key, val);
    if (result) *result = CFRetain(val);
    pthread_mutex_unlock(&s_keychain_lock);
    return errSecSuccess;
}
DYLD_INTERPOSE(shim_SecItemAdd, SecItemAdd);
```

### 4.3. Оконная интеграция и завершение процесса (`mod_window_close.m`)
Внедрение обработчика `NSWindowWillCloseNotification` для корректного выхода:

```objc
#import <AppKit/AppKit.h>

__attribute__((constructor))
static void init_window_close(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSWindow *w = [note object];
        if (![w isKindOfClass:[NSWindow class]] || !([w styleMask] & NSWindowStyleMaskTitled)) return;
        [NSApp terminate:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            _exit(0);
        });
    }];
}
```

### 4.4. Инъекция dylib и переподпись
```bash
# Внедрение загрузочной команды LC_LOAD_DYLIB
python3 engine/insert_dylib.py Payload/PCalc.app/PCalc "@executable_path/libshim.dylib"

# Рекурсивная ad-hoc переподпись
codesign -f -s - Payload/PCalc.app/libshim.dylib
codesign -f -s - --deep Payload/PCalc.app
```

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Fully Working**
- **UI / UX**: Полная поддержка кликов мышью и трекпадом, адаптивный ресайзинг окна без искажения пропорций кнопок, переключение инженерного режима, сохранение состояния.
- **Рецептурный файл**: `recipes/com.pcalc.mobile.ini`

```ini
[metadata]
name = PCalc
bundle_id = com.pcalc.mobile
tested_version = 3.7.5
engine = native_cocoatouch_c
rendering = uikit_coregraphics
sound_system = system_audio

[window]
aspect_ratio = free
resizable = true
scale_mode = native

[shims]
keychain = in_memory
activation_policy = regular
window_close_exit = true
path_redirect = documents
```
