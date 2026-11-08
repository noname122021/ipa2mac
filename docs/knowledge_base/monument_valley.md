# Case Study: Monument Valley (Unity IL2CPP & Multi-Binary Framework)

Authoritative case study and technical post-mortem for running Monument Valley on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Monument Valley
- **Bundle Identifier**: `com.ustwo.monumentvalley`
- **Tested Version**: 2.10.2 (Build 2.10.2.149)
- **Minimum iOS Version**: iOS 11.0
- **Engine / Architecture**: Unity 2020.3.21f1 (IL2CPP 64-bit Ahead-Of-Time compiled)
- **Graphics Backend**: Apple Metal Pipeline
- **Audio Stack**: Unity CoreAudio / FMOD
- **Window Profile**: 9:16 Portrait Aspect Ratio (540x960), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

Monument Valley от студии ustwo games — шедевр пространственных оптических иллюзий и медитативной архитектуры Эшера.

Приложение тестировалось на шагах 120–150 диалога (коммиты `bcdd7e5`, `b7790b7`, `dd467df`). Кейс стал показательным примером архитектуры современных Unity-приложений, где исполняемый код вынесен в динамический фреймворк, а рантайм IL2CPP предъявляет жесткие требования к селекторам Foundation.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Архитектура Multi-Binary: `UnityFramework.framework`
Начиная с версии Unity 2019.3+, структура iOS-проектов разделена на два Mach-O бинарника:
1. `Payload/MonumentValley.app/MonumentValley` (~50 КБ) — тонкий загрузчик AppKit/UIKit.
2. `Payload/MonumentValley.app/Frameworks/UnityFramework.framework/UnityFramework` (~45 МБ) — все скомпилированные C++ скрипты IL2CPP, сам движок Unity, ресурсы и физика.

Если конвертировать только главный бинарник, dyld падает с ошибкой несовместимости платформы при попытке загрузить `UnityFramework`.

### 3.2. Крах рантайма IL2CPP на селекторе `dictionaryRepresentation`
В игре реализована синхронизация открытых глав через iCloud KVS. В отличие от старых версий движка, Unity 2020 в реализации сохранения вызывает:
```objc
NSDictionary *dict = [[NSUbiquitousKeyValueStore defaultStore] dictionaryRepresentation];
```
В раннем моке `NSUbiquitousKeyValueStore` данный селектор отсутствовал. Рантайм IL2CPP моментально выбрасывал необработанное исключение:
```text
-[NSUbiquitousKeyValueStore dictionaryRepresentation]: unrecognized selector sent to instance 0x10...
*** Terminating app due to uncaught exception 'NSInvalidArgumentException'
```

---

## 4. Что мы применили (Applied Solution)

### 4.1. Каскадная конвертация `UnityFramework.framework`
Скрипт `patch_app.sh` детектирует наличие `UnityFramework` и выполняет разметку `vtool`:
```bash
vtool -set-build-version maccatalyst 14.0 14.0 -replace \
    -output Payload/MonumentValley.app/Frameworks/UnityFramework.framework/UnityFramework \
    Payload/MonumentValley.app/Frameworks/UnityFramework.framework/UnityFramework
```

### 4.2. Расширение мока `NSUbiquitousKeyValueStore` (`mod_ubiquitous.m`)
Добавление реализации селектора `dictionaryRepresentation`:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static CFMutableDictionaryRef s_ubiDict = NULL;

static id hook_dictionaryRepresentation(id self, SEL _cmd) {
    if (!s_ubiDict) return [NSDictionary dictionary];
    return (__bridge id)s_ubiDict;
}

__attribute__((constructor))
static void init_ubiquitous_dictionary_fix(void) {
    Class cls = objc_getClass("NSUbiquitousKeyValueStore");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, sel_registerName("dictionaryRepresentation"));
    if (m) {
        method_setImplementation(m, (IMP)hook_dictionaryRepresentation);
    } else {
        class_addMethod(cls, sel_registerName("dictionaryRepresentation"), 
                        (IMP)hook_dictionaryRepresentation, "@@:");
    }
}
```

### 4.3. Оконный профиль 9:16
Установка портретного разрешения `540x960` с масштабированием `aspect_fit`, обеспечивающим четкие геометрические линии изометрических башен.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / 60 FPS Flawless**
- **Игровой процесс**: Вращение оптических платформ, перемещение принцессы Иды, пространственные трансформации уровней, чистейший атмосферный звук и сохранение прогресса глав.
- **Рецептурный файл**: `recipes/com.ustwo.monumentvalley.ini`

```ini
[metadata]
name = Monument Valley
bundle_id = com.ustwo.monumentvalley
tested_version = 2.10.2
engine = unity_il2cpp
rendering = metal
sound_system = unity_coreaudio

[window]
width = 540
height = 960
aspect_ratio = 9:16
resizable = true
orientation = portrait
scale_mode = aspect_fit

[shims]
ubiquitous_store = true
ubiquitous_dictionary_representation = true
frameworks_retag = UnityFramework.framework
assert_suppress = true
keychain = in_memory
path_redirect = documents
activation_policy = regular
```
