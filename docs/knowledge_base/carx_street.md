# Case Study: CarX Street (Unity IL2CPP & Metal)

Authoritative case study and technical post-mortem for running CarX Street on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: CarX Street
- **Bundle Identifier**: `com.carxtech.sr`
- **Tested Version**: 1.24.0 (Build 1004)
- **Minimum iOS Version**: iOS 15.0
- **Engine / Architecture**: Unity 6000.0.64f1 (IL2CPP 64-bit)
- **Graphics Backend**: Metal (Apple M-series Silicon native GfxDevice)
- **Audio Stack**: FMOD / CoreAudio
- **Window Profile**: 16:9 Landscape (1280x720), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

CarX Street — один из наиболее требовательных к графике современных открытых гоночных симуляторов на iOS (объем клиента свыше 3 ГБ, процедурный рендеринг ночного города, тяжелый физический движок шин).

Интеграция велась на шагах 3343–3750 диалога (коммиты `b6412b2`, `496d4b2`, `bb754c8`, `dd467df`). Для профилирования и проверки запуска был запущен субагент **CarX Street Runner** (`44d3ba67-f18c-48d3-8d11-60c5c570d8b9`), зафиксировавший стабильную работу Metal-конвейера на Apple M1 с активным потреблением 93–155% CPU и 780 МБ RAM.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Блокирующая проверка свободного места на диске (`statfs` / `statvfs`)
При старте встроенный менеджер загрузки ассетов CarX выполняет опрос системного хранилища через POSIX-вызовы `statfs` и `statvfs`, а также через Foundation API `NSURLVolumeAvailableCapacityKey`. Если объем доступного дискового пространства меньше жестко заданного порога (64 ГБ), игра прерывает запуск и выводит модальное окно ошибки нехватки памяти или завершается аварийно.

### 3.2. Зависание на On-Demand Resources (ODR / `NSBundleResourceRequest`)
Игра активно использует технологию Apple On-Demand Resources для фоновой докачки моделей автомобилей и геометрии районов. В среде Mac Catalyst без подключения к серверам App Store метод `[NSBundleResourceRequest beginAccessingResourcesWithCompletionHandler:]` зависал бесконечно, блокируя поток загрузки Unity.

### 3.3. Отсутствие бандла Unity Addressables (`shared_assets_all.bundle`)
В структуре ассетов `Data/Raw/aa/BuildTarget` менеджер адресов Unity искал бандл с именем `shared_assets_all.bundle`. В сборке присутствовал файл `shared_prefabs_assets_all.bundle`. При отсутствии точного имени ресурса загрузчик ассетов бросал исключение `Addressables: Unable to load asset bundle`.

### 3.4. Dyld Image Registration Deadlock (`fishhook`)
Присутствие аналитических и рекламных модулей со встроенной библиотекой `fishhook` вызывало классический дедлок dyld при регистрации динамических образов (`_dyld_register_func_for_add_image`).

### 3.5. Занижение графического профиля на Apple Silicon
Без аппаратного спуфинга игра определяла устройство как generic desktop, отключая шейдеры динамического освещения и отражений.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Спуфинг дискового пространства 64 ГБ (`mod_statfs.c`)
Интерпозиция функций файловой статистики ядра для эмуляции объема свободного диска:

```c
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <string.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

// Эмулируем ~64 ГБ свободного места: 16777216 блоков по 4096 байт
static int shim_statfs(const char *path, struct statfs *buf) {
    int ret = statfs(path, buf);
    if (buf) {
        buf->f_bsize = 4096;
        buf->f_blocks = 33554432;   // 128 GB total
        buf->f_bfree = 16777216;    // 64 GB free
        buf->f_bavail = 16777216;   // 64 GB available
    }
    return ret;
}
DYLD_INTERPOSE(shim_statfs, statfs);

static int shim_statvfs(const char *path, struct statvfs *buf) {
    int ret = statvfs(path, buf);
    if (buf) {
        buf->f_bsize = 4096;
        buf->f_frsize = 4096;
        buf->f_blocks = 33554432;
        buf->f_bfree = 16777216;
        buf->f_bavail = 16777216;
    }
    return ret;
}
DYLD_INTERPOSE(shim_statvfs, statvfs);
```

### 4.2. Байпас On-Demand Resources (`mod_odr_bypass.m`)
Перехват методов `NSBundleResourceRequest` с мгновенным возвратом успешного статуса:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef void (^ODRCompletionBlock)(NSError * _Nullable error);

static void hook_beginAccessing(id self, SEL _cmd, ODRCompletionBlock completion) {
    NSLog(@"[CarX-Airlift] ODR bypass: instant access granted for tags %@", [self valueForKey:@"tags"]);
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
    }
}

static void hook_conditionallyBegin(id self, SEL _cmd, void (^completion)(BOOL resourcesAvailable)) {
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES);
        });
    }
}

__attribute__((constructor))
static void init_odr_bypass(void) {
    Class cls = objc_getClass("NSBundleResourceRequest");
    if (!cls) return;
    
    Method m1 = class_getInstanceMethod(cls, sel_registerName("beginAccessingResourcesWithCompletionHandler:"));
    if (m1) method_setImplementation(m1, (IMP)hook_beginAccessing);
    
    Method m2 = class_getInstanceMethod(cls, sel_registerName("conditionallyBeginAccessingResourcesWithCompletionHandler:"));
    if (m2) method_setImplementation(m2, (IMP)hook_conditionallyBegin);
}
```

### 4.3. Автоматическое дублирование бандла Addressables в `patch_app.sh`
```bash
# Unity Addressables dependency fix (CarX Street)
AA_DIR="$APP_BUNDLE/Data/Raw/aa/BuildTarget"
if [ -d "$AA_DIR" ] && [ -f "$AA_DIR/shared_prefabs_assets_all.bundle" ] && [ ! -f "$AA_DIR/shared_assets_all.bundle" ]; then
    echo "    [-] Bundling shared_assets_all.bundle for Addressables..."
    cp "$AA_DIR/shared_prefabs_assets_all.bundle" "$AA_DIR/shared_assets_all.bundle"
fi
```

### 4.4. Аппаратный спуфинг `iPad13,8`
В `mod_device_spoof.c` задана модель `iPad13,8` (iPad Pro 11" 3-го поколения на базе процессора Apple M1), что автоматически активирует максимальный профиль графики Metal.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Active Process on Metal**
- **Метрики запуска**: PID 32690, размер окна 1280x720 (активный заголовок `CarX Street`), инициализирован нативный GfxDevice `Apple M1` (Unity 6000.0.64f1), лог подтверждает: `disk free 65747 MB` и `Available capacity: 68941553664`.
- **Рецептурный файл**: `recipes/com.carxtech.sr.ini`

```ini
[metadata]
name = CarX Street
bundle_id = com.carxtech.sr
tested_version = 1.24.0
engine = unity_il2cpp
rendering = metal
sound_system = fmod_coreaudio

[window]
width = 1280
height = 720
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
hardware_model = iPad13,8
statfs_spoof = true
odr_bypass = true
dyld_fishhook_suppress = true
keychain = in_memory
activation_policy = regular
```
