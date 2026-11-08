# Case Study: JAVser (Compose Multiplatform & AVFoundation)

Authoritative case study and technical post-mortem for running JAVser on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: JAVser
- **Bundle Identifier**: `com.guro.javser`
- **Tested Version**: 1.0.0
- **Minimum iOS Version**: iOS 16.0
- **Engine / Architecture**: Compose Multiplatform (Kotlin/Native)
- **Graphics Backend**: Skiko / Metal
- **Audio & Video Stack**: AVFoundation (`AVPlayer`, `AVPlayerLayer`, `CoreMedia`)
- **Window Profile**: Free / Aspect Unlocked, Resizable (`900x700`, `scale_mode = native`)

---

## 2. Контекст запуска и хронология

JAVser представлял собой современное iOS-приложение (iOS 16+), построенное на стеке **Kotlin Multiplatform + Jetpack Compose for iOS** с рендерингом на графическом движке **Skiko (Metal)** и сетевым видеоплеером на базе **AVFoundation**.

Задача решалась на поздних этапах проекта (шаги ~3300–3340 диалога, коммиты `bb754c8` и `dd467df`). В ходе тестирования был задействован специализированный субагент **AVFoundation & Shim Diagnostic** (`821ef64d-6a66-44dd-9939-a6df20aec801`), выявивший критический побочный эффект «глобального шимминга» на современные видеопотоки.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Недостающие символы BackgroundTasks (`_OBJC_CLASS_$_BGContinuedProcessingTaskRequest`)
При запуске бинарника dyld немедленно падал с ошибкой разрешения динамических символов:
```text
dyld: Symbol not found: _OBJC_CLASS_$_BGContinuedProcessingTaskRequest
  Referenced from: /Payload/JAVser.app/JAVser
  Expected in: /System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks
```
В iOS 16+ появился класс `BGContinuedProcessingTaskRequest`, который в macOS Catalyst 14.0 отсутствовал в системном фреймворке `BackgroundTasks.framework`.

### 3.2. Вечный фриз сетевого видеотранслятора (`AVPlayer`)
Интерфейс приложения загружался, каталоги отображались, однако при нажатии на воспроизведение видео плеер зависал на нулевой секунде с вечным индикатором буферизации. 

Глубокий анализ потоков и CoreMedia показал комплексную причину:
1. **Захват и повреждение `AVAudioSession`**: В ранней монолитной версии `shim.m` конструктор `init_audio_early` безусловно подменял методы `AVAudioSession` для всех приложений подряд. Селектор `opaqueSessionID` возвращал фиктивное число `10001`. Для работы `AVPlayerItem` и синхронизации часов `CoreMedia` (Master Timebase Clock) аудиосессия обязана была зарегистрироваться в системном демоне `mediaserverd`. Получив некорректный ID сессии, аудиовывод блокировал синхронизацию таймлайна, и `AVPlayer` бесконечно ждал готовности аудиотракта.
2. **Коллизия фреймворка BackgroundTasks**: Скрипт `patch_app.sh` безусловно перенаправлял `BackgroundTasks.framework` на `libshim.dylib` через `install_name_tool`, а `build_shim.sh` реэкспортировал системный фреймворк. Это вызвало конфликт классов `Class BGTaskScheduler is implemented in both...`, ломая системные загрузчики медиа-ассетов.
3. **Глобальное подавление dyld callbacks**: Перехват `_dyld_register_func_for_add_image` глушил регистрацию динамических декодеров `VideoToolbox` (`VTVideoDecoder`), не позволяя аппаратно декодировать H.264/HEVC.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Архитектурный переход к рецептурному изолированию (Zero-Leakage Shims)
Мы разделили агрессивные хаки для старых игр и нативные мультимедийные интерфейсы. В `patch_app.sh` и `mod_audio_legacy.m` включение хуков `AVAudioSession` стало строгим: только если в `recipe.ini` явно указано `audio_session_fix = true`. Для JAVser эта опция отключена.

### 4.2. Стабы классов BackgroundTasks (`mod_bg_classes.m`)
Вместо грязного перенаправления всего фреймворка мы создали чистые заглушки недостающих классов в Objective-C:

```objc
#import <Foundation/Foundation.h>

@interface BGContinuedProcessingTask : NSObject @end
@implementation BGContinuedProcessingTask @end

@interface BGContinuedProcessingTaskRequest : NSObject @end
@implementation BGContinuedProcessingTaskRequest @end

@interface BGTaskRequest : NSObject @end
@implementation BGTaskRequest @end

@interface BGAppRefreshTaskRequest : BGTaskRequest @end
@implementation BGAppRefreshTaskRequest @end

@interface BGProcessingTaskRequest : BGTaskRequest @end
@implementation BGProcessingTaskRequest @end
```

### 4.3. Выборочное перенаправление фреймворка в `patch_app.sh`
```bash
# Redirect BackgroundTasks.framework ONLY if enabled or if missing symbols detected
if [ "$BG_REDIRECT" = "true" ] || strings "$bin" 2>/dev/null | grep -q "BGContinuedProcessingTask"; then
    if otool -L "$bin" 2>/dev/null | grep -q "BackgroundTasks.framework"; then
        echo "    [-] Redirecting BackgroundTasks.framework to libshim.dylib..."
        local bg_path=$(otool -L "$bin" | grep "BackgroundTasks.framework" | awk '{print $1}')
        if [ -n "$bg_path" ]; then
            install_name_tool -change "$bg_path" "@executable_path/libshim.dylib" "$bin" 2>/dev/null || true
        fi
    fi
fi
```

### 4.4. Пропуск регистрации dynamic image callbacks
В `mod_dyld_fishhook.c` регистрация функций в dyld подавляется только при наличии флага `dyld_fishhook_suppress = true`. В остальных случаях вызов прозрачно передается в системный `libdyld.dylib`, сохраняя регистрацию кодеков VideoToolbox.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Fully Working**
- **UI / UX**: Идеальный рендеринг Jetpack Compose через Skiko/Metal, плавный скроллинг списков, стабильное онлайн-воспроизведение видео со звуком без задержек.
- **Рецептурный файл**: `recipes/com.guro.javser.ini`

```ini
[metadata]
name = JAVser
bundle_id = com.guro.javser
tested_version = 1.0.0
engine = compose_multiplatform_kotlin_native
rendering = skiko_metal
sound_system = avfoundation

[window]
width = 900
height = 700
aspect_ratio = free
resizable = true
orientation = free
scale_mode = native

[shims]
keychain = in_memory
activation_policy = regular
window_styling = true
window_close_exit = true
path_redirect = documents
background_tasks_redirect = true
```
