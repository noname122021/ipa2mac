# Case Study: Alto's Adventure (Unity 5 & iCloud Key-Value Store Mock)

Authoritative case study and technical post-mortem for running Alto's Adventure on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Alto's Adventure
- **Bundle Identifier**: `com.snowman.alto`
- **Tested Version**: 1.6.2 (Build 2)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: Unity 5.1.4f1 (64-bit arm64)
- **Graphics Backend**: Apple Metal Pipeline
- **Audio Stack**: Unity CoreAudio
- **Window Profile**: 16:9 Landscape (960x540), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

Alto's Adventure от студии Snowman — атмосферный процедурный сноубординг по заснеженным холмам, построенный на ранней 64-битной версии движка Unity 5.

Тестирование и адаптация проводились на шагах 110–140 диалога (коммиты `bcdd7e5`, `b7790b7`, `dd467df`). Кейс стал ключевым подтверждением работоспособности эмуляции облачного хранилища iCloud (KVS) в изолированной среде.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Фатальный ассерт при обращении к iCloud KVS
Сразу после логотипа Snowman игра падала с системным ассертом:
```text
*** Assertion failure in -[NSUbiquitousKeyValueStore init], NSUbiquitousKeyValueStore.m:64
BUG IN CLIENT OF KVS: NSUbiquitousKeyValueStore initialized without entitlement
Abort trap: 6
```
**Причина**: Движок Unity 5 при старте подсистемы сохранений пытается синхронизировать рекорды расстояния, монеты и открытых персонажей через `[NSUbiquitousKeyValueStore defaultStore]`. На Mac Catalyst вызов этого API у приложения без платной подписи Apple Developer Program и активированного entitlement `com.apple.developer.ubiquity-kvstore-identifier` карается мгновенным `SIGABRT`.

### 3.2. Преждевременное завершение процесса при отпускании кнопки мыши (Mouse-Up Trap)
При одиночном клике (прыжок сноубордиста) обработчик событий AppKit перехватывал событие `mouseUp` как закрытие модального контекста, инициируя завершение приложения.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Полнофункциональный In-Memory мок `NSUbiquitousKeyValueStore` (`mod_ubiquitous.m`)
Свиззлинг методов `defaultStore`, `objectForKey:`, `stringForKey:`, `longLongForKey:`, `setObject:forKey:` и `synchronize` с сохранением данных в статический словарь `CFMutableDictionaryRef`:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static CFMutableDictionaryRef s_ubiDict = NULL;

static id hook_defaultStore(id self, SEL _cmd) { 
    return self; 
}

static id hook_objectForKey(id self, SEL _cmd, NSString *key) {
    if (!key || !s_ubiDict) return nil;
    return (id)CFDictionaryGetValue(s_ubiDict, (__bridge const void *)(key));
}

static void hook_setObject(id self, SEL _cmd, id obj, NSString *key) {
    if (!key || !s_ubiDict) return;
    if (obj) {
        CFDictionarySetValue(s_ubiDict, (__bridge const void *)(key), (__bridge const void *)(obj));
    } else {
        CFDictionaryRemoveValue(s_ubiDict, (__bridge const void *)(key));
    }
}

static id hook_stringForKey(id self, SEL _cmd, NSString *key) { 
    return hook_objectForKey(self, _cmd, key); 
}

static long long hook_longLongForKey(id self, SEL _cmd, NSString *key) {
    id val = hook_objectForKey(self, _cmd, key);
    return [val respondsToSelector:@selector(longLongValue)] ? [val longLongValue] : 0;
}

static BOOL hook_synchronize(id self, SEL _cmd) { 
    return YES; 
}

__attribute__((constructor))
static void init_ubiquitous_store(void) {
    s_ubiDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    Class cls = objc_getClass("NSUbiquitousKeyValueStore");
    if (!cls) return;

    Method m = class_getClassMethod(cls, sel_registerName("defaultStore"));
    if (m) method_setImplementation(m, (IMP)hook_defaultStore);

    Method m_inst = class_getInstanceMethod(cls, sel_registerName("objectForKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_objectForKey);
    m_inst = class_getInstanceMethod(cls, sel_registerName("stringForKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_stringForKey);
    m_inst = class_getInstanceMethod(cls, sel_registerName("longLongForKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_longLongForKey);
    m_inst = class_getInstanceMethod(cls, sel_registerName("setObject:forKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_setObject);
    m_inst = class_getInstanceMethod(cls, sel_registerName("synchronize"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_synchronize);
}
```

### 4.2. Защита события Mouse-Up (`window_close_guard`)
Фильтрация событий отпускания кнопки мыши для предотвращения ложного закрытия окна во время выполнения бэкфлипов и прыжков.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / 60 FPS Solid**
- **Игровой процесс**: Процедурная смена дня и ночи, погодные бури и молнии, сбор монет, сальто через пропасти, управление пробелом или кликом мыши, полное сохранение прогресса в сессии.
- **Рецептурный файл**: `recipes/com.snowman.alto.ini`

```ini
[metadata]
name = Alto's Adventure
bundle_id = com.snowman.alto
tested_version = 1.6.2
engine = unity_5
rendering = metal
sound_system = unity_coreaudio

[window]
width = 960
height = 540
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
ubiquitous_store = true
window_close_guard = true
keychain = in_memory
assert_suppress = true
path_redirect = documents
activation_policy = regular
```
