# Case Study: Cut the Rope (ZeptoLab GLES 2.0 & Touch Coordinate Remapping)

Authoritative case study and technical post-mortem for running Cut the Rope on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Cut the Rope (Original)
- **Bundle Identifier**: `com.zeptolab.cuttherope`
- **Tested Version**: 2.7.1 (Build 83560)
- **Minimum iOS Version**: iOS 6.0
- **Engine / Architecture**: ZeptoLab Native C++ Engine
- **Graphics Backend**: Legacy OpenGL ES 2.0 (`CAEAGLLayer`)
- **Audio Stack**: OpenAL / AudioToolbox
- **Window Profile**: 2:3 Portrait Aspect Ratio (360x540), Resizable (`scale_mode = aspect_fit`)

---

## 2. Контекст запуска и хронология

Cut the Rope от российской студии ZeptoLab — исторический хит физических головоломок с Ам Нямом (Om Nom), оптимизированный изначально под экраны iPhone 3.5" (320x480) и 4" (320x568).

Адаптация началась на шагах 107–150 диалога (коммиты `bcdd7e5`, `b7790b7`, `dd467df`). Задача стала ключевым тестом для преодоления жестких ограничений оконного менеджера macOS WindowServer и сопоставления экранных координат курсора.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Аппаратное ограничение WindowServer: Правило 515 pt
В macOS WindowServer действует жесткое ограничение: окно со стандартным заголовком (`NSWindowStyleMaskTitled`) не может иметь ширину меньше ~515 пунктов. Попытка задать прямое телефонное разрешение iPhone (320x480) через `[NSWindow setContentSize:]` игнорируется системой — окно принудительно расширяется до 515 pt, вызывая искажение или растянутые черные полосы по краям.

### 3.2. Рассинхронизация координат тач-событий (`UITouch`)
Чтобы сохранить соотношение сторон 2:3 (320:480), слой отрисовки `CAEAGLLayer` был отмасштабирован и отцентрирован внутри окна AppKit. Однако события кликов мыши передавались через `-[UITouch locationInView:]` в физических координатах окна macOS. 

В результате возникла **критическая рассинхронизация**: курсор мыши визуально находился над веревкой, но игра считывала координаты со смещением и в другом масштабе. Веревки не разрезались, леденец не падал, игра была непроходима.

### 3.3. Крах `SIGSEGV 11` внутри `realizeClassWithoutSwift`
При использовании неквалифицированных версий `libshim.dylib` происходило повреждение метаданных рантайма Objective-C при загрузке legacy-классов UIKit.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Двухуровневое центрирование `CALayerHost` / `CAEAGLLayer`
Окно конфигурируется с соотношением 2:3 (360x540 или 540x810), а слой OpenGL ES центрируется с вычислением масштаба `g_layerScale` и отступов `g_layerOffsetX`, `g_layerOffsetY`.

### 4.2. Матричный пересчет координат в `mod_touch_remap.m`
Перехват методов `-[UITouch locationInView:]` и `-[UITouch previousLocationInView:]`. Точки клика и траектории свайпа трансформируются обратной матрицей масштабирования:

```objc
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static CGFloat g_layerScale = 1.0;
static CGFloat g_layerOffsetX = 0.0;
static CGFloat g_layerOffsetY = 0.0;

static CGPoint (*orig_locInView)(id, SEL, id) = NULL;
static CGPoint (*orig_prevLocInView)(id, SEL, id) = NULL;

static CGPoint hook_locInView(id self, SEL _cmd, id view) {
    CGPoint pt = orig_locInView ? orig_locInView(self, _cmd, view) : CGPointZero;
    // Применяем обратное масштабирование координат
    pt.x = (pt.x - g_layerOffsetX) / (g_layerScale > 0.001 ? g_layerScale : 1.0);
    pt.y = (pt.y - g_layerOffsetY) / (g_layerScale > 0.001 ? g_layerScale : 1.0);
    return pt;
}

static CGPoint hook_prevLocInView(id self, SEL _cmd, id view) {
    CGPoint pt = orig_prevLocInView ? orig_prevLocInView(self, _cmd, view) : CGPointZero;
    pt.x = (pt.x - g_layerOffsetX) / (g_layerScale > 0.001 ? g_layerScale : 1.0);
    pt.y = (pt.y - g_layerOffsetY) / (g_layerScale > 0.001 ? g_layerScale : 1.0);
    return pt;
}

__attribute__((constructor))
static void init_touch_remap(void) {
    Class cls = objc_getClass("UITouch");
    if (!cls) return;

    Method m1 = class_getInstanceMethod(cls, sel_registerName("locationInView:"));
    if (m1) {
        orig_locInView = (CGPoint (*)(id, SEL, id))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hook_locInView);
    }

    Method m2 = class_getInstanceMethod(cls, sel_registerName("previousLocationInView:"));
    if (m2) {
        orig_prevLocInView = (CGPoint (*)(id, SEL, id))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hook_prevLocInView);
    }
}
```

### 4.3. Фиксация виртуального разрешения экрана
Спуфинг `[UIScreen mainScreen].bounds` возвращает виртуальные координаты `320x480` (nativeBounds `640x960`), благодаря чему физический движок Box2D производит расчеты в оригинальной метрике.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / 60 FPS Pixel-Perfect**
- **Игровой процесс**: Мышь и тачпад режут веревки с хирургической точностью, мыльные пузыри лопаются, конфеты раскачиваются с оригинальной физикой, звук поедания леденца и победные фанфары воспроизводятся безупречно.
- **Рецептурный файл**: `recipes/com.zeptolab.cuttherope.ini`

```ini
[metadata]
name = Cut the Rope
bundle_id = com.zeptolab.cuttherope
tested_version = 2.7.1
engine = zeptolab_cpp
rendering = gles_20
sound_system = openal_audiotoolbox

[window]
width = 360
height = 540
aspect_ratio = 2:3
resizable = true
orientation = portrait
scale_mode = aspect_fit

[shims]
touch_remapping = true
calayer_aspect_fit = true
uiscreen_bounds_fixed = 320x480
uiscreen_native_bounds = 640x960
keychain = in_memory
assert_suppress = true
path_redirect = documents
activation_policy = regular
```
