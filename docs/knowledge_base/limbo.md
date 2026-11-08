# Case Study: LIMBO (Playdead C++ Engine & GameCenter Modal Bypass)

Authoritative case study and technical post-mortem for running LIMBO on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: LIMBO
- **Bundle Identifier**: `com.playdeadgames.limbo.ios`
- **Tested Version**: 1.1.28 (and 1.1.19 / Build 1.1.19.2)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: Playdead Proprietary C++ Engine
- **Graphics Backend**: Custom Metal Pipeline
- **Audio Stack**: FMOD Studio / CoreAudio
- **Window Profile**: 16:9 Landscape (1152x648), Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

LIMBO by Playdead is a monochromatic puzzle-platformer featuring a custom C++ renderer executing directly on Apple Metal.

Diagnosing this target resolved game engine crashes caused by unrecognized Apple Silicon model strings and UI freezes caused by unfulfilled GameKit authentication blocks.

---

## 3. Root Cause Analysis

### 3.1. Crash on Unrecognized Hardware Model (`hw.machine`)
During initialization, Playdead's engine parses machine hardware profiles via `sysctlbyname("hw.machine")`. On Apple Silicon, Darwin returned host model identifiers (`"Mac14,2"`, `"Mac15,3"`). Missing from the engine's internal lookup tables, this caused either an immediate abort:
```text
Fatal Error: Unknown device hardware profile 'Mac14,2'
```
or forced fallback to low-resolution graphics with post-processing disabled.

### 3.2. Infinite Hang on "Loading..." Screen (Game Center Trap)
Immediately following the splash screen, the display remained permanently stuck on `Loading...`.

**Cause**: The engine registered an authentication handler with GameKit:
```objc
[GKLocalPlayer localPlayer].authenticateHandler = ^(UIViewController *viewController, NSError *error) { ... };
```
Under Mac Catalyst in an ad-hoc signed environment without Game Center entitlements, the system daemon never dispatched the completion block. The engine waited indefinitely before initializing the main menu.

### 3.3. dyld Recursive Interposing Collision
Blindly interposing `sysctlbyname` broke `libdyld.dylib`, which relies on `sysctl` during dynamic linker bootstrap to query page sizes and CPU feature flags.

---

## 4. Applied Mitigations

### 4.1. Hardware Spoofing with Caller Address Filtering (`device_spoof.c`)
Returns `"iPad8,1"` (iPad Pro 11-inch 1st Gen), using `__builtin_return_address(0)` and `dladdr` to bypass calls originating inside `libdyld`:

```c
#include <sys/types.h>
#include <sys/sysctl.h>
#include <string.h>
#include <dlfcn.h>
#include <errno.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static int shim_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    void *caller = __builtin_return_address(0);
    Dl_info dlinfo;
    if (dladdr(caller, &dlinfo) && dlinfo.dli_fname && strstr(dlinfo.dli_fname, "libdyld")) {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    
    if (name && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)) {
        const char *val = "iPad8,1";
        size_t len = strlen(val) + 1;
        if (oldp == NULL) { if (oldlenp) *oldlenp = len; return 0; }
        if (oldlenp && *oldlenp < len) return ENOMEM;
        strcpy((char *)oldp, val);
        if (oldlenp) *oldlenp = len;
        return 0;
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
DYLD_INTERPOSE(shim_sysctlbyname, sysctlbyname);
```

### 4.2. Automatic Game Center Authentication (`game_center_auto_auth.m`)
Swizzled `-[GKLocalPlayer setAuthenticateHandler:]`. Once the engine provides the block, the shim invokes it asynchronously with `(nil, nil)`, signaling successful completion:

```objc
#import <GameKit/GameKit.h>
#import <objc/runtime.h>

typedef void (^GKAuthBlock)(UIViewController * _Nullable viewController, NSError * _Nullable error);

static void hook_setAuthenticateHandler(id self, SEL _cmd, GKAuthBlock handler) {
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(nil, nil);
    });
}

__attribute__((constructor))
static void init_gamecenter(void) {
    Class cls = objc_getClass("GKLocalPlayer");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("setAuthenticateHandler:"));
    if (m) method_setImplementation(m, (IMP)hook_setAuthenticateHandler);
}
```

---

## 5. Status & Verification

- **Status**: **Verified / 60 FPS Native Metal**
- **Gameplay**: Instant main menu entry, custom volumetric fog, dynamic lighting shaders on Metal, responsive keyboard and mouse controls.
- **Recipe File**: `recipes/com.playdeadgames.limbo.ios.ini`

```ini
[metadata]
name = LIMBO
bundle_id = com.playdeadgames.limbo.ios
tested_version = 1.1.28
engine = playdead_cpp
rendering = custom_metal
sound_system = fmod_coreaudio

[window]
width = 1152
height = 648
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
hardware_model = iPad8,1
game_center_auto_auth = true
keychain = in_memory
assert_suppress = true
path_redirect = documents
activation_policy = regular

[overrides:1.1.19]
hardware_model = iPad7,1
game_center_auto_auth = true
```
