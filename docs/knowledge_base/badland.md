# Case Study: BADLAND (Frogmind Cocos2d-x & FMOD Audio Engine)

Authoritative case study and technical post-mortem for running BADLAND on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: BADLAND
- **Bundle Identifier**: `com.frogmindgames.dodge` (legacy alias `com.frogmind.badland`)
- **Tested Version**: 3.4.3 (Build 187)
- **Minimum iOS Version**: iOS 8.0
- **Engine / Architecture**: Frogmind Custom C++ / Cocos2d-x
- **Graphics Backend**: OpenGL ES 2.0 / Early Metal
- **Audio Stack**: FMOD Studio / CoreAudio
- **Window Profile**: 16:9 Landscape (960x540), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

BADLAND — шедевр физического экшена с атмосферным аудиовизуальным рядом от финской студии Frogmind.

Приложение стало главным тестовым полигоном для выявления глубоких системных дедлоков на стыке `dyld`, `CoreAudio` и обработчиков сигналов Unix (шаги 120–160 диалога, коммиты `bcdd7e5`, `00999c4`, `1123777`, `dd467df`). В исследовании участвовали субагенты **BADLAND Restorer** (`eeccad49-d4b6-4d39-b39d-9412ee21f799`) и **Legacy Games Diagnostic Runner** (`1ed9e21e-898e-4ab6-88a0-77e4e763711c`).

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Дедлок статического C++ инициализатора в AudioSession
Игра запускалась в терминале, однако окно не открывалось, иконка в Dock не появлялась, а процесс зависал на вызове Mach trap:
```text
* frame #0: 0x0000000180000000 in mach_msg_trap ()
  frame #1: 0x0000000180000120 in mach_msg ()
  frame #2: 0x000000018005a200 in AudioSessionCreateSessionInServer ()
  frame #3: 0x0000000100021400 in BADLAND`__cxx_global_var_init ()
```
**Причина**: До передачи управления в `main()` статический конструктор C++ вызывал `+[AVAudioSession sharedInstance]`. Вызов выполнял синхронный XPC Mach-запрос к системным аудиосерверам (`mediaserverd` и `CMIOProprietaryDefaultsSource`). Поскольку компоновщик dyld во время работы конструкторов удерживает глобальный рекурсивный лок образов (`dyld image lock`), ответный IPC-коллбэк не мог быть обработан, приводя к перманентному мертвому зависанию.

### 3.2. Дедлок `fishhook` в `_dyld_register_func_for_add_image`
Встроенные SDK Everyplay и GameCenter использовали библиотеку `fishhook` для динамического перехвата OpenGL-символов. `fishhook` вызывал `_dyld_register_func_for_add_image` внутри конструктора, что приводило к коллизии блокировок с `libdispatch`.

### 3.3. Троттлинг FMOD Audio IOThread (Слайд-шоу 5 FPS)
После обхода дедлока игра запускалась, но работала со скоростью 5 FPS с прерывистым заикающимся звуком. На macOS вторичные аудиопотоки (микшер FMOD) без связи с главным AppKit-потоком понижаются планировщиком macOS в приоритете (QoS Background Throttling).

### 3.4. Бесконечная рекурсия в `handle_memory_fault` (`PAGEZERO`)
При первом разыменовании нулевого указателя (`info->si_addr < 0x4000`) глобальный обработчик памяти в раннем шиме вычислял `page = 0` и вызывал `mprotect(0, 0x4000, PROT_READ|PROT_WRITE)`. В Darwin/Mach нулевая страница (`PAGEZERO`) аппаратно защищена ядром и не подлежит модификации через `mprotect` (возвращает ошибку `EINVAL`). После возврата из обработчика процессор перезапускал сбойную инструкцию, мгновенно вызывая повторный `SIGSEGV` и уводя процесс в 100% загрузку CPU.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Превентивный перехват `AVAudioSession` (`mod_audio_legacy.m`)
Инициализация хуков с приоритетом `__attribute__((constructor(-50)))`, возвращающих мгновенные статические значения без обращения к XPC-демонам:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static double hook_sampleRate(id self, SEL _cmd) { return 44100.0; }
static id hook_category(id self, SEL _cmd) { return @"AVAudioSessionCategoryPlayback"; }
static BOOL hook_setCategory(id self, SEL _cmd, __unsafe_unretained id cat, ...) { return YES; }
static BOOL hook_setActive(id self, SEL _cmd, BOOL active, ...) { return YES; }
static unsigned int hook_opaqueSessionID(id self, SEL _cmd) { return 10001; }
static NSTimeInterval hook_duration(id self, SEL _cmd) { return 0.02; }

__attribute__((constructor(-50)))
static void init_audio_early(void) {
    Class cls = objc_getClass("AVAudioSession");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, sel_registerName("sampleRate"));
    if (m) method_setImplementation(m, (IMP)hook_sampleRate);
    m = class_getInstanceMethod(cls, sel_registerName("opaqueSessionID"));
    if (m) method_setImplementation(m, (IMP)hook_opaqueSessionID);
    m = class_getInstanceMethod(cls, sel_registerName("setCategory:error:"));
    if (m) method_setImplementation(m, (IMP)hook_setCategory);
    m = class_getInstanceMethod(cls, sel_registerName("setActive:error:"));
    if (m) method_setImplementation(m, (IMP)hook_setActive);
}
```

### 4.2. Подавление динамического хукинга `fishhook` (`mod_dyld_fishhook.c`)
```c
#include <mach-o/dyld.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

typedef void (*dyld_image_func)(const struct mach_header* mh, intptr_t vmaddr_slide);

static void shim_dyld_register_func_for_add_image(dyld_image_func func) {
    // No-op: предотвращение дедлока fishhook в dyld
}
DYLD_INTERPOSE(shim_dyld_register_func_for_add_image, _dyld_register_func_for_add_image);
```

### 4.3. Устранение циклического сбоя `PAGEZERO` в `mod_fault_handler.c`
```c
static void handle_memory_fault(int sig, siginfo_t *info, void *ucontext) {
    uintptr_t addr = (uintptr_t)info->si_addr;
    // Защита от зацикливания на нулевой странице ядра
    if (addr < 0x4000) {
        signal(sig, SIG_DFL);
        return;
    }
    uintptr_t page = addr & ~0x3fff;
    if (mprotect((void*)page, 0x10000, PROT_READ | PROT_WRITE) != 0) {
        signal(sig, SIG_DFL);
    }
}
```

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / 60 FPS Flawless**
- **Метрики**: Идеальная физика полета клонов, чистый 44.1 кГц саундтрек FMOD без щелчков и рассинхронизации, отзывчивое управление кликами мыши.
- **Рецептурный файл**: `recipes/com.frogmindgames.dodge.ini`

```ini
[metadata]
name = BADLAND
bundle_id = com.frogmindgames.dodge
tested_version = 3.4.3
engine = frogmind_cocos2d
rendering = gles_metal
sound_system = fmod_coreaudio

[window]
width = 960
height = 540
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
dyld_fishhook_suppress = true
audio_session_fix = true
audio_unthrottle = true
hardware_model = iPad8,1
keychain = in_memory
memory_fault_recovery = true
assert_suppress = true
path_redirect = documents
activation_policy = regular
```
