# Case Study: EcoFlow (React Native & Tablet Idiom Adaptation)

Authoritative case study and technical post-mortem for running EcoFlow on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: EcoFlow (Oversea)
- **Bundle Identifier**: `com.ef.EcoFlow`
- **Tested Version**: 6.11.0 (Build 92)
- **Minimum iOS Version**: iOS 15.1
- **Engine / Architecture**: Native Swift / Objective-C + React Native Framework
- **Graphics Backend**: UIKit / CoreAnimation / Metal
- **Audio Stack**: System Audio
- **Window Profile**: 3:4 Portrait Aspect Ratio (768x1024), Non-Resizable (`resizable = false`, `scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

EcoFlow — современный клиент управления портативными зарядными станциями, солнечными генераторами и элементами умного дома по Bluetooth и Wi-Fi.

Задача решалась на шагах 3330–3345 диалога (коммиты `bb754c8`, `dd467df`). В разработке участвовал субагент **UI & Layout Compatibility** (`44ff3260-0bd2-4746-a5dd-95638a131f20`), которому было поручено устранить верстку телефонного интерфейса и обеспечить четкий планшетный дэшборд.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Искажение лейаута из-за неверного `UIUserInterfaceIdiom`
React Native определяет стили компонентов и плотность сетки карточек через обращение к `[UIDevice currentDevice].userInterfaceIdiom`. 
- В среде Mac Catalyst без вмешательства данный метод возвращал `5` (`UIUserInterfaceIdiomMac`) либо `0` (`UIUserInterfaceIdiomPhone`).
- Движок React Native не знал значения `5` и переключался в режим мобильного телефона, в результате чего виджеты мощности батареи сжимались в узкую вертикальную колонку, шрифты становились нечитаемыми, а flex-контейнеры выходили за пределы экрана.

### 3.2. Ложные метрики `[UIScreen mainScreen].bounds`
Метод `[UIScreen mainScreen].bounds` возвращал физическое разрешение дисплея Mac (1440x900 pt). Модуль `Dimensions.get('window')` в JavaScript считал, что экран имеет ширину 1440 pt при высоте 900 pt, вызывая чудовищные горизонтальные разрывы верстки.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Принудительный планшетный идиом в `mod_window.m`
Свиззлинг `[UIDevice userInterfaceIdiom]` для жесткого возврата значения `1` (`UIUserInterfaceIdiomPad`):

```objc
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIUserInterfaceIdiom hook_userInterfaceIdiom(id self, SEL _cmd) {
    return UIUserInterfaceIdiomPad; // Возвращаем iPad (1)
}

__attribute__((constructor))
static void init_device_idiom(void) {
    Class cls = objc_getClass("UIDevice");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("userInterfaceIdiom"));
    if (m) method_setImplementation(m, (IMP)hook_userInterfaceIdiom);
}
```

### 4.2. Калибровка виртуального экрана `[UIScreen bounds]` под размеры окна
Перехват экранных границ для привязки к реальному размеру контента окна (768x1024):

```objc
static CGRect hook_screenBounds(id self, SEL _cmd) {
    NSWindow *w = [NSApp keyWindow] ?: [[NSApp windows] firstObject];
    if (w && [w contentView]) {
        NSRect r = [[w contentView] bounds];
        if (r.size.width > 100 && r.size.height > 100) {
            return CGRectMake(0, 0, r.size.width, r.size.height);
        }
    }
    return CGRectMake(0, 0, 768.0, 1024.0);
}
```

### 4.3. Фиксация окна 3:4 без ресайзинга (`resizable = false`)
В `com.ef.EcoFlow.ini` зафиксированы размеры `width = 768`, `height = 1024`, что предотвращает деформацию карточек телеметрии.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Tablet Quality**
- **UI / UX**: Просторный планшетный дэшборд, анимация графиков энергопотребления, стабильная авторизация через in-memory keychain, отсутствие горизонтального скролла.
- **Рецептурный файл**: `recipes/com.ef.EcoFlow.ini`

```ini
[metadata]
name = EcoFlow
bundle_id = com.ef.EcoFlow
tested_version = 6.11.0
engine = native_swift_objc
rendering = uikit_metal
sound_system = system_audio

[window]
width = 768
height = 1024
aspect_ratio = 3:4
resizable = false
orientation = portrait
scale_mode = aspect_fit

[shims]
user_interface_idiom = pad
hardware_model = iPad8,1
keychain = in_memory
activation_policy = regular
window_styling = true
window_close_exit = true
path_redirect = documents
```
