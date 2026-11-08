# Case Study: VLC for Mobile (Multi-Framework Retagging & LibVLC)

Authoritative case study and technical post-mortem for running VLC for Mobile on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: VLC for Mobile
- **Bundle Identifier**: `org.videolan.vlc-ios`
- **Tested Version**: 3.0.2 (Build 303)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: Native Swift & Objective-C / `libvlc` C Engine
- **Graphics Backend**: UIKit / Metal / OpenGL ES (Video Output Layer)
- **Audio Stack**: CoreAudio / AudioUnit
- **Window Profile**: Free / Aspect Unlocked, Resizable (`960x600`, `scale_mode = native`)

---

## 2. Контекст запуска и хронология

VLC for Mobile — популярнейший открытый мультимедийный комбайн, способный воспроизводить любые аудио- и видеокодеки без конвертации.

Тестирование проходило на шагах 113–120 диалога (коммиты `bcdd7e5`, `b7790b7`, `dd467df`). Этот кейс заставил кардинально расширить функциональность скрипта `patch_app.sh`, заложив основу для рекурсивного патчинга вложенных динамических библиотек и фреймворков.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Крах dyld на вложенных фреймворках (`wrong platform`)
При начальной реализации `vtool` модифицировал только главный исполняемый файл `Payload/VLC for iOS.app/VLC for iOS`. Однако VLC содержит тяжелые скомпилированные динамические фреймворки в каталоге `Frameworks/`:
- `MobileVLCKit.framework` (сам движок libvlc, кодеки FFmpeg, демультиплексоры)
- `MediaLibraryKit.framework` (индексация локальных медиа-файлов)

При запуске системный загрузчик dyld немедленно падал:
```text
dyld: Library not loaded: @rpath/MobileVLCKit.framework/MobileVLCKit
  Referenced from: /Payload/VLC for iOS.app/VLC for iOS
  Reason: mach-o, but wrong platform (expected 6 [Mac Catalyst], got 2 [iOS])
```

### 3.2. Нарушение подписи вложенных dylib (`Code Signature Invalid`)
Изменение Mach-O заголовка во вложенном фреймворке без инвалидации и повторной подписи приводило к отказу ядра macOS загружать библиотеку в общее адресное пространство процесса.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Автоматический рекурсивный обход и конвертация Mach-O в `patch_app.sh`
Мы модернизировали процедуру конвертации, добавив рекурсивный поиск всех исполняемых бинарников внутри бандла:

```bash
# Recursively patch frameworks and dylibs
find "$APP_BUNDLE" -type f ! -name "libshim.dylib" | while read -r file; do
    if file "$file" | grep -q "Mach-O"; then
        chmod +x "$file" 2>/dev/null || true
        if [ "$file" != "$MAIN_BIN" ]; then
            patch_binary "$file"
        fi
    fi
done
```

Где процедура `patch_binary` выполняет:
1. Выделение среза `arm64` через `lipo -thin arm64`.
2. Замену платформы на Mac Catalyst 14.0 через `vtool -set-build-version maccatalyst 14.0 14.0 -replace`.

### 4.2. Иерархическая ad-hoc переподпись «снизу вверх»
```bash
# 1. Подписываем вложенные Mach-O файлы
find "$APP_BUNDLE" -type f ! -name "libshim.dylib" | while read -r f; do
    if file "$f" | grep -q "Mach-O"; then
        codesign -f -s - "$f" 2>/dev/null || true
    fi
done

# 2. Подписываем структуру .framework каталогов
find "$APP_BUNDLE/Frameworks" -type d -name "*.framework" 2>/dev/null | while read -r fw; do
    codesign -f -s - "$fw" 2>/dev/null || true
done

# 3. Финальная глубокая подпись всего App Bundle
codesign -f -s - --deep "$APP_BUNDLE"
```

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Fully Working Media Player**
- **Возможности**: Аппаратное воспроизведение видеофайлов (MKV, MP4, AVI) через libvlc, свободное изменение размера окна с авто-масштабированием видеопотока, работающий аудиотракт CoreAudio.
- **Рецептурный файл**: `recipes/org.videolan.vlc-ios.ini`

```ini
[metadata]
name = VLC for Mobile
bundle_id = org.videolan.vlc-ios
tested_version = 3.0.2
engine = native_swift_libvlc
rendering = uikit_metal_opengl
sound_system = coreaudio_audiounit

[window]
width = 960
height = 600
aspect_ratio = free
resizable = true
orientation = free
scale_mode = native

[shims]
multi_framework_retag = MobileVLCKit.framework,MediaLibraryKit.framework
network_entitlements = true
keychain = in_memory
path_redirect = documents
activation_policy = regular
window_styling = true
window_close_exit = true
```
