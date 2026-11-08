# Case Study: DEVICE 6 (Simogo Narrative & Orientation Engine)

Authoritative case study and technical post-mortem for running DEVICE 6 on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: DEVICE 6
- **Bundle Identifier**: `com.simogo.devicesix`
- **Tested Version**: 1.4 (Build 0)
- **Minimum iOS Version**: iOS 8.0
- **Engine / Architecture**: Simogo Custom Native Objective-C Engine
- **Graphics Backend**: UIKit / OpenGL ES
- **Audio Stack**: CoreAudio / System Audio
- **Window Profile**: 3:4 Portrait Aspect Ratio (768x1024), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

DEVICE 6 от шведской студии Simogo — один из самых оригинальных шедевров интерактивного повествования в истории iOS, удостоенный Apple Design Award.

Адаптация проводилась на шагах 3340–3350 диалога (коммиты `bb754c8` и `dd467df`). В решении участвовал субагент **UI & Layout Compatibility** (`44ff3260-0bd2-4746-a5dd-95638a131f20`), которому предстояло решить уникальную геймдизайнерскую проблему адаптации мобильного управления под десктоп.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Геймплейная зависимость от физического поворота устройства
В DEVICE 6 текст книги и аудиовизуальные улики буквально разветвляются по экрану в разных направлениях. Чтобы продолжить чтение, игрок обязан физически поворачивать планшет iPad в руках на 90°, 180° и 270°. На настольном компьютере Mac или ноутбуке MacBook физический поворот корпуса невозможен.

### 3.2. Отсутствие акселерометра и заблокированная ориентация в Mac Catalyst
Mac Catalyst работает в фиксированной оконной парадигме и не предоставляет доступа к аппаратному датчику гравитации (акселерометру). Вызовы `[UIDevice currentDevice].orientation` всегда возвращали `UIDeviceOrientationPortrait`, делая прохождение игры принципиально невозможным.

### 3.3. Необходимость сохранения фиксированного планшетного соотношения 3:4
При свободной растяжке окна текст романа распадался на несвязанные фрагменты. Игре требовалось строгое соблюдение пропорций экрана iPad (3:4).

---

## 4. Что мы применили (Applied Solution)

### 4.1. Внедрение виртуального меню поворота в системный MenuBar (`mod_d6_rotation.m`)
Мы разработали специальный модуль, который перехватывает инициализацию `NSApp mainMenu` и встраивает системное меню «Rotate Device» с горячими клавишами (`Cmd+R` / `Cmd+Shift+R`). Меню напрямую модифицирует внутреннее состояние `UIDevice` и рассылает системные нотификации:

```objc
#import <AppKit/AppKit.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIDeviceOrientation s_currentOrientation = UIDeviceOrientationPortrait;

@interface D6RotationController : NSObject
@end

@implementation D6RotationController
+ (void)rotateClockwise {
    switch (s_currentOrientation) {
        case UIDeviceOrientationPortrait:           s_currentOrientation = UIDeviceOrientationLandscapeLeft; break;
        case UIDeviceOrientationLandscapeLeft:      s_currentOrientation = UIDeviceOrientationPortraitUpsideDown; break;
        case UIDeviceOrientationPortraitUpsideDown: s_currentOrientation = UIDeviceOrientationLandscapeRight; break;
        case UIDeviceOrientationLandscapeRight:     s_currentOrientation = UIDeviceOrientationPortrait; break;
        default:                                    s_currentOrientation = UIDeviceOrientationPortrait; break;
    }
    [self notifyOrientationChange];
}

+ (void)notifyOrientationChange {
    NSLog(@"[DEVICE 6] Hardware rotation dispatched: %ld", (long)s_currentOrientation);
    [[NSNotificationCenter defaultCenter] postNotificationName:UIDeviceOrientationDidChangeNotification
                                                        object:[UIDevice currentDevice]];
}
@end

static UIDeviceOrientation hook_deviceOrientation(id self, SEL _cmd) {
    return s_currentOrientation;
}

__attribute__((constructor))
static void init_d6_rotation(void) {
    // Подменяем ориентацию в UIDevice
    Class uidevCls = objc_getClass("UIDevice");
    if (uidevCls) {
        Method m = class_getInstanceMethod(uidevCls, @selector(orientation));
        if (m) method_setImplementation(m, (IMP)hook_deviceOrientation);
    }

    // Создаем пункт меню в AppKit
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenu *mainMenu = [NSApp mainMenu];
        if (!mainMenu) return;

        NSMenuItem *rotateMenu = [[NSMenuItem alloc] initWithTitle:@"Rotate Device" action:nil keyEquivalent:@""];
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Rotate Device"];

        NSMenuItem *itemCW = [[NSMenuItem alloc] initWithTitle:@"Rotate 90° Clockwise" 
                                                        action:@selector(rotateClockwise) 
                                                 keyEquivalent:@"r"];
        [itemCW setTarget:[D6RotationController class]];
        [submenu addItem:itemCW];

        [rotateMenu setSubmenu:submenu];
        [mainMenu addItem:rotateMenu];
    });
}
```

### 4.2. Жесткая фиксация соотношения сторон 3:4 (`mod_window.m`)
В рецепте задана геометрия `768x1024` с aspect-fit центрированием, что точно воспроизводит размеры дисплея iPad Retina.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Fully Playable Narrative Experience**
- **Управление**: Скроллинг текста и интерактивные переключатели управляются трекпадом/мышью. При достижении поворотов сюжета игрок нажимает `Cmd+R` в меню, текст плавно вращается, а загадки разблокируются.
- **Рецептурный файл**: `recipes/com.simogo.devicesix.ini`

```ini
[metadata]
name = DEVICE 6
bundle_id = com.simogo.devicesix
tested_version = 1.4
engine = native_objc
rendering = uikit_gles
sound_system = system_audio

[window]
width = 768
height = 1024
aspect_ratio = 3:4
resizable = true
orientation = portrait
scale_mode = aspect_fit

[shims]
keychain = in_memory
activation_policy = regular
window_styling = true
window_close_exit = true
path_redirect = documents
device_rotation_menu = true
```
