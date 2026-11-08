# Case Study: Grand Theft Auto: Vice City (RenderWare & OpenAL 3D)

Authoritative case study and technical post-mortem for running GTA Vice City on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Grand Theft Auto: Vice City
- **Bundle Identifier**: `com.rockstargames.gta3vc`
- **Tested Version**: 1.5.1 (Build 1.5.1)
- **Minimum iOS Version**: iOS 5.1.1 (64-bit arm64 maintenance release)
- **Engine / Architecture**: War Drum Studios / RenderWare Custom C++
- **Graphics Backend**: Legacy OpenGL ES 2.0 / 3.0
- **Audio Stack**: OpenAL 3D Audio Engine / AudioQueue
- **Window Profile**: 16:9 Landscape (960x540 / 1280x720), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

Grand Theft Auto: Vice City — культовый открытый 3D-мир от Rockstar Games, портированный студией War Drum Studios на мобильные платформы к 10-летнему юбилею игры.

Проект присутствует в эталонном каталоге `apps_test/gta_vice_city` и запускается через `run_gta_vice_city.command`. Кейс доказал возможность запуска классических тяжелых C++ игровых движков начала 2010-х годов с трехмерным открытым миром, транспортом и потоковым воспроизведением радиостанций.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Запись сейвов и настроек в несуществующую песочницу
War Drum Studios использует собственную реализацию сохранения состояния мира (`save.b`) и конфигурации управления (`setting.a`). При отсутствии прав записи в домашний каталог пользователя процесс завершался аварийно при попытке создать файл автосохранения после первой вступительной кат-сцены у отеля Ocean View.

### 3.2. Нарушение работы аудиотракта OpenAL при инициализации
Игра использует низкоуровневые контексты OpenAL (`alcOpenDevice`, `alcCreateContext`) с аппаратным микшированием десятков источников звука (моторы машин, шум волн, радиостанции, диалоги). При блокировке `AVAudioSession` в Mac Catalyst системный звуковой сервер не выделял аппаратный аудиодевайс, приводя к зависанию на черном экране с логотипом Rockstar North.

### 3.3. Сенсорное управление и координаты виртуального джойстика
Вся схема управления (газ, тормоз, стрельба, выбор радио) была жестко завязана на экранный тач-интерфейс.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Конвертация заголовка платформы и инъекция dylib
```bash
# Конвертация Mach-O платформы
vtool -set-build-version maccatalyst 14.0 14.0 -replace \
    -output apps_test/gta_vice_city/Payload/gta3vc.app/gta3vc \
    apps_test/gta_vice_city/Payload/gta3vc.app/gta3vc

# Подключение libshim.dylib через загрузочную команду
python3 ipa2mac/engine/insert_dylib.py \
    apps_test/gta_vice_city/Payload/gta3vc.app/gta3vc \
    "@executable_path/libshim.dylib"
```

### 4.2. Изоляция файлов сохранения через `CFFIXED_USER_HOME`
В конструкторе `libshim.dylib` настраивается безопасный доступ к документам:
```objc
NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
setenv("CFFIXED_USER_HOME", [docPath UTF8String], 1);
```
Все сейв-файлы Tommy Vercetti корректно записываются и загружаются между перезапусками.

### 4.3. Аппаратный спуфинг `iPad8,1` (`mod_device_spoof.c`)
Спуфинг модели через `sysctl` и `uname` активирует поддержку увеличенной дальности прорисовки (Draw Distance), теней высокого разрешения и динамического освещения неоновых вывесок Вайс-Сити.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Fully Playable Open-World**
- **Игровой процесс**: Томми Версетти свободно перемещается по городу, угоняет спорткары, стреляет, слушает все радиостанции (Flash FM, Wave 103, V-Rock) в идеальном стереозвучании, миссии сохраняются и загружаются.
- **Скрипт запуска**: `apps_test/run_gta_vice_city.command`
```bash
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$DIR/gta_vice_city/Payload/gta3vc.app"
echo "=== Launching GTA Vice City ==="
DYLD_INSERT_LIBRARIES="$APP_DIR/libshim.dylib" "$APP_DIR/gta3vc"
```
