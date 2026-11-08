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

## 2. Context & Chronology

DEVICE 6 by Simogo is an interactive narrative puzzle adventure designed specifically around physical iPad handling and orientation.

Adapting this game required addressing a unique design challenge: translating device-tilt gameplay mechanics into a desktop-friendly interface.

---

## 3. Root Cause Analysis

### 3.1. Gameplay Dependency on Physical Device Rotation
In DEVICE 6, text lines and clues branch across the screen in four cardinal directions. Progressing through chapters requires physically rotating the tablet by 90°, 180°, and 270°. On a stationary Mac or MacBook, physical rotation is not feasible.

### 3.2. Absence of Accelerometer and Locked Orientation in Catalyst
Mac Catalyst runs in a windowed paradigm and lacks hardware accelerometer feeds. Calls to `[UIDevice currentDevice].orientation` consistently returned `UIDeviceOrientationPortrait`, completely blocking puzzle progression.

### 3.3. Strict 3:4 iPad Geometry Requirement
Unconstrained window resizing broke typographic alignment. The game requires a rigid 3:4 aspect ratio to keep narrative paths intact.

---

## 4. Applied Mitigations

### 4.1. AppKit MenuBar Rotation Injection (`device_rotation_menu.m`)
Integrated a custom menu item into the macOS system menu bar (`Cmd+R` / `Rotate Device`). The action updates `UIDevice` state and dispatches orientation notifications:

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
    Class uidevCls = objc_getClass("UIDevice");
    if (uidevCls) {
        Method m = class_getInstanceMethod(uidevCls, @selector(orientation));
        if (m) method_setImplementation(m, (IMP)hook_deviceOrientation);
    }

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

### 4.2. Fixed 3:4 Aspect Clamp (`mod_window.m`)
Configured `768x1024` geometry with aspect-fit letterboxing, replicating iPad Retina proportions.

---

## 5. Status & Verification

- **Status**: **Verified / Fully Playable Narrative Experience**
- **Controls**: Scrolling and interaction map cleanly to mouse and trackpad. Pressing `Cmd+R` rotates typography dynamically, allowing all puzzles to be solved.
- **Recipe File**: `recipes/com.simogo.devicesix.ini`

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
