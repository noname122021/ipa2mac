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

## 2. Context & Chronology

EcoFlow is an energy management client for portable power stations, solar generators, and smart home appliances communicating over Bluetooth and Wi-Fi.

This case required resolving mobile phone layout degradation to enforce a tablet-optimized dashboard layout.

---

## 3. Root Cause Analysis

### 3.1. Layout Degradation from Ambiguous `UIUserInterfaceIdiom`
React Native determines component layouts and card grids by querying `[UIDevice currentDevice].userInterfaceIdiom`.
- Under standard Mac Catalyst, this API returns `5` (`UIUserInterfaceIdiomMac`) or `0` (`UIUserInterfaceIdiomPhone`).
- Unaware of value `5`, React Native fell back to compact phone mode, shrinking battery power widgets into a cramped column with clipped text and broken flex containers.

### 3.2. Misaligned Screen Metrics (`[UIScreen mainScreen].bounds`)
Calling `[UIScreen mainScreen].bounds` returned the physical display metrics of the Mac (e.g. 1440x900 pt). JavaScript's `Dimensions.get('window')` inferred a 1440 pt wide viewport, disrupting horizontal responsive layouts.

---

## 4. Applied Mitigations

### 4.1. Enforcing Tablet Idiom (`mod_window.m`)
Swizzled `[UIDevice userInterfaceIdiom]` to return `1` (`UIUserInterfaceIdiomPad`):

```objc
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIUserInterfaceIdiom hook_userInterfaceIdiom(id self, SEL _cmd) {
    return UIUserInterfaceIdiomPad; // Force iPad (1)
}

__attribute__((constructor))
static void init_device_idiom(void) {
    Class cls = objc_getClass("UIDevice");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("userInterfaceIdiom"));
    if (m) method_setImplementation(m, (IMP)hook_userInterfaceIdiom);
}
```

### 4.2. Calibrating Virtual Screen Bounds to Window Frame
Bound `[UIScreen bounds]` queries to the window's content rect (`768x1024`):

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

### 4.3. Fixed 3:4 Window Dimensions (`resizable = false`)
Set `width = 768`, `height = 1024` in `recipes/com.ef.EcoFlow.ini` to prevent telemetry card distortion.

---

## 5. Status & Verification

- **Status**: **Verified / Tablet Quality**
- **UI / UX**: Clean iPad dashboard layout, animated power consumption graphs, stable session storage via in-memory keychain, zero horizontal clipping.
- **Recipe File**: `recipes/com.ef.EcoFlow.ini`

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
