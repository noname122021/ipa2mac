# Case Study: LIMBO (Playdead C++ Engine & GameCenter Modal Bypass)

Authoritative case study and technical post-mortem for running LIMBO on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: LIMBO
- **Bundle Identifier**: `com.playdeadgames.limbo.ios`
- **Tested Version**: 1.1.28 (and 1.1.19 / Build 1.1.19.2)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: Playdead Proprietary C++ Engine
- **Graphics Backend**: Custom Metal Pipeline
- **Audio Stack**: FMOD Studio / CoreAudio
- **Window Profile**: 16:9 Landscape (1152x648), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

LIMBO от датской независимой студии Playdead — эталонный мрачный платформер-головоломка, портированный на iOS с проприетарным C++ рендерером под Apple Metal.

Анализ и адаптация проводились на шагах 130–170 диалога (коммиты `bcdd7e5`, `b7790b7`, `dd467df`). Основную диагностику блокирующего зависания интерфейса провел субагент **Legacy Games Diagnostic Runner** (`1ed9e21e-898e-4ab6-88a0-77e4e763711c`).

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Падение на неизвестной модели оборудования (`hw.machine`)
Движок Playdead при старте парсит аппаратный профиль через вызов `sysctlbyname("hw.machine")`. На компьютерах Apple Silicon функция возвращала реальные строки хоста (`"Mac14,2"`, `"Mac15,3"`). В таблице профилей игры строки отсутствовали, что приводило либо к аварийному завершению:
```text
Fatal Error: Unknown device hardware profile 'Mac14,2'
```
либо к переключению на ультра-низкое разрешение с отключением пост-процессинга и зернистости.

### 3.2. Зависание на вечном экране «Loading...» (Game Center Modal Trap)
Сразу после заставки Playdead экран темнел и появлялась бесконечная надпись `Loading...`. 

**Причина**: Движок регистрировал блок аутентификации через GameKit:
```objc
[GKLocalPlayer localPlayer].authenticateHandler = ^(UIViewController *viewController, NSError *error) { ... };
```
В среде Mac Catalyst при запуске ad-hoc приложения без entitlements демоны Game Center не вызывали зарегистрированный обработчик ни с успехом, ни с ошибкой. Движок ожидал завершения авторизации перед инициализацией главного меню, оставаясь в бесконечном цикле ожидания.

### 3.3. Ловушка dyld при перехвате `sysctlbyname`
Ранние попытки прямого перехвата `sysctlbyname` ломали сам компоновщик `libdyld.dylib`, который использует `sysctl` для определения размера страниц памяти и возможностей CPU.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Избирательный аппаратный спуфинг с проверкой вызывающего (`mod_device_spoof.c`)
Спуфинг возвращает строку `"iPad8,1"` (iPad Pro 11-inch 1st Gen) или `"iPad7,1"`, но использует `__builtin_return_address(0)` и `dladdr` для пропуска системных вызовов из `libdyld`:

```c
#include <sys/types.h>
#include <sys/sysctl.h>
#include <string.h>
#include <dlfcn.h>
#include <errno.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static int shim_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    void *caller = __builtin_return_address(0);
    Dl_info dlinfo;
    // Пропускаем системные проверки из libdyld
    if (dladdr(caller, &dlinfo) && dlinfo.dli_fname && strstr(dlinfo.dli_fname, "libdyld")) {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    
    if (name && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)) {
        const char *val = "iPad8,1";
        size_t len = strlen(val) + 1;
        if (oldp == NULL) { if (oldlenp) *oldlenp = len; return 0; }
        if (oldlenp && *oldlenp < len) return ENOMEM;
        strcpy((char *)oldp, val);
        if (oldlenp) *oldlenp = len;
        return 0;
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
DYLD_INTERPOSE(shim_sysctlbyname, sysctlbyname);
```

### 4.2. Автоматическое завершение GameKit-аутентификации (`mod_gamecenter.m`)
Свиззлинг метода `setAuthenticateHandler:`. Как только игра передает блок, шим асинхронно вызывает его с аргументами `(nil, nil)`, сигнализируя об успешном пропуске логина:

```objc
#import <GameKit/GameKit.h>
#import <objc/runtime.h>

typedef void (^GKAuthBlock)(UIViewController * _Nullable viewController, NSError * _Nullable error);

static void hook_setAuthenticateHandler(id self, SEL _cmd, GKAuthBlock handler) {
    if (!handler) return;
    NSLog(@"[LIMBO-Airlift] GKLocalPlayer setAuthenticateHandler intercepted -> auto-invoking");
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(nil, nil);
    });
}

__attribute__((constructor))
static void init_gamecenter(void) {
    Class cls = objc_getClass("GKLocalPlayer");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("setAuthenticateHandler:"));
    if (m) method_setImplementation(m, (IMP)hook_setAuthenticateHandler);
}
```

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / 60 FPS Native Metal**
- **Игровой процесс**: Моментальный вход в главное меню без зависаний, глубокий фирменный туман и эффекты освещения Metal, безупречная поддержка клавиатуры и мыши.
- **Рецептурный файл**: `recipes/com.playdeadgames.limbo.ios.ini`

```ini
[metadata]
name = LIMBO
bundle_id = com.playdeadgames.limbo.ios
tested_version = 1.1.28
engine = playdead_cpp
rendering = custom_metal
sound_system = fmod_coreaudio

[window]
width = 1152
height = 648
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
hardware_model = iPad8,1
game_center_auto_auth = true
keychain = in_memory
assert_suppress = true
path_redirect = documents
activation_policy = regular

[overrides:1.1.19]
hardware_model = iPad7,1
game_center_auto_auth = true
```
