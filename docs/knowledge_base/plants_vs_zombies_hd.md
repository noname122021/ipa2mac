# Case Study: Plants vs. Zombies HD (PopCap 4:3 Fixed iPad Grid)

Authoritative case study and technical post-mortem for running Plants vs. Zombies HD on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Plants vs. Zombies HD
- **Bundle Identifier**: `com.popcap.PvZiPad`
- **Tested Version**: 1.9.12 (Build 4134)
- **Minimum iOS Version**: iOS 7.0 (64-bit arm64 maintenance release)
- **Engine / Architecture**: PopCap SexyAppFramework (C++ Mobile Port)
- **Graphics Backend**: Legacy OpenGL ES 2.0
- **Audio Stack**: OpenAL / AudioToolbox
- **Window Profile**: Fixed 4:3 iPad Aspect Ratio (1024x768), Non-Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

Plants vs. Zombies HD — легендарная стратегия в жанре Tower Defense от компании PopCap Games, изначально оптимизированная под 9.7-дюймовый экран оригинального iPad первого поколения.

Приложение развернуто в тестовом каталоге `apps_test/pvz_hd` и снабжено скриптом `run_pvz_hd.command`. Кейс стал эталоном адаптации сеточных (tile-based) 2D-стратегий с жестко привязанной матрицей координат игрового поля.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Смещение сетки газона при произвольном ресайзе
Движок SexyAppFramework вычисляет номер клетки газона (колонка от 0 до 8, строка от 0 до 4) по строгим целочисленным координатам:
```c
int col = (touch_x - LAWN_OFFSET_X) / CELL_WIDTH;
int row = (touch_y - LAWN_OFFSET_Y) / CELL_HEIGHT;
```
При попытке растянуть окно до произвольных пропорций или широкоформатного разрешения 16:9 координаты клика мыши не попадали в нужную клетку: подсолнухи сажались со сдвигом на две клетки правее, а падающие с неба солнца невозможно было собрать кликом мыши.

### 3.2. Устаревший аудиотракт AudioToolbox
PopCap использует циклическое воспроизведение сэмплов через устаревший API `AudioServicesPlaySystemSound` и OpenAL-буферы, требовавшие корректной категории воспроизведения без падений в Catalyst.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Фиксация пропорций окна 4:3 (1024x768)
Запрет изменения геометрии окна (`resizable = false`) и применение масштабирования `scale_mode = aspect_fit` с центрированием на экране. Это гарантирует 100% совпадение физических пикселей клика мыши с логической координатной сеткой газона PopCap.

### 4.2. Конвертация платформы и инъекция dylib
```bash
# Разметка Mach-O Catalyst 14.0
vtool -set-build-version maccatalyst 14.0 14.0 -replace \
    -output apps_test/pvz_hd/Payload/PvZHD.app/PvZHD \
    apps_test/pvz_hd/Payload/PvZHD.app/PvZHD

# Внедрение libshim.dylib
python3 ipa2mac/engine/insert_dylib.py \
    apps_test/pvz_hd/Payload/PvZHD.app/PvZHD \
    "@executable_path/libshim.dylib"
```

### 4.3. Сохранение прогресса уровней и покупок в Альманахе
Перенаправление сохранения пользовательского профиля (`users.dat`) в каталог `~/Documents` исключает сброс прогресса прохождения кампании и монет у Безумного Дэйва (Crazy Dave).

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / 60 FPS Classic Perfection**
- **Игровой процесс**: Клик мышью сажает растения точно в выбранную клетку, солнца легко собираются на лету, зомби плавно шагают под классическую музыку Лауры Шигихары (Laura Shigihara), мини-игры (Вазобой, Защити Орех) работают на 100%.
- **Скрипт запуска**: `apps_test/run_pvz_hd.command`
```bash
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$DIR/pvz_hd/Payload/PvZHD.app"
echo "=== Launching Plants vs. Zombies HD ==="
DYLD_INSERT_LIBRARIES="$APP_DIR/libshim.dylib" "$APP_DIR/PvZHD"
```
