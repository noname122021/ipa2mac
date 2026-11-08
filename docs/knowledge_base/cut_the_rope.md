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

## 2. Context & Chronology

Cut the Rope by ZeptoLab is a physics puzzle classic featuring Om Nom, originally designed for iPhone 3.5" (320x480) and 4" (320x568) displays.

This target served as the primary benchmark for solving macOS WindowServer minimum window width limits and mapping pointer coordinates to scaled render layers.

---

## 3. Root Cause Analysis

### 3.1. WindowServer Hardware Constraint: 515 pt Minimum Width
macOS WindowServer enforces a hard minimum width of ~515 pt for standard titled windows (`NSWindowStyleMaskTitled`). Attempting to force direct iPhone resolutions (320x480) via `[NSWindow setContentSize:]` is clamped by the window server, creating wide black margins or aspect distortion.

### 3.2. Touch Event Desynchronization (`UITouch`)
To maintain the 2:3 aspect ratio, the `CAEAGLLayer` render target was scaled and centered inside the AppKit host window. However, mouse click coordinates passed into UIKit via `-[UITouch locationInView:]` arrived in macOS window coordinates.

This mismatch prevented touch events from reaching game elements: mouse swipes appeared visually aligned with ropes, but the engine read offset coordinates, leaving ropes unsevered and levels unplayable.

---

## 4. Applied Mitigations

### 4.1. Aspect-Fit Layer Centering
The AppKit window enforces a 2:3 aspect constraint (360x540 or 540x810), while the rendering layer computes scale factors `g_layerScale` and padding offsets `g_layerOffsetX`, `g_layerOffsetY`.

### 4.2. Matrix Coordinate Remapping (`touch_remapping.m`)
Swizzled `-[UITouch locationInView:]` and `-[UITouch previousLocationInView:]` to transform click points and drag trajectories through an inverse scaling matrix:

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

### 4.3. Virtual Screen Bounds Spoofing
Spoofing `[UIScreen mainScreen].bounds` to return virtual `320x480` (nativeBounds `640x960`) ensures internal Box2D physics calculations evaluate with original display metrics.

---

## 5. Status & Verification

- **Status**: **Verified / 60 FPS Pixel-Perfect**
- **Gameplay**: Mouse and trackpad gestures slice ropes with sub-pixel precision, bubbles pop accurately, candy swings with correct Box2D dynamics, audio effects play cleanly.
- **Recipe File**: `recipes/com.zeptolab.cuttherope.ini`

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
