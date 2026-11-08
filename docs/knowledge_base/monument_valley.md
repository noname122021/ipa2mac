# Case Study: Monument Valley (Unity IL2CPP & Multi-Binary Framework)

Authoritative case study and technical post-mortem for running Monument Valley on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Monument Valley
- **Bundle Identifier**: `com.ustwo.monumentvalley`
- **Tested Version**: 2.10.2 (Build 2.10.2.149)
- **Minimum iOS Version**: iOS 11.0
- **Engine / Architecture**: Unity 2020.3.21f1 (IL2CPP 64-bit Ahead-Of-Time compiled)
- **Graphics Backend**: Apple Metal Pipeline
- **Audio Stack**: Unity CoreAudio / FMOD
- **Window Profile**: 9:16 Portrait Aspect Ratio (540x960), Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

Monument Valley by ustwo games is a puzzle adventure based on optical illusions and isometric geometry.

This case exemplified modern Unity application structures where core executable code is housed inside a separate dynamic framework, while the IL2CPP runtime requires specific Foundation selectors.

---

## 3. Root Cause Analysis

### 3.1. Multi-Binary Architecture: `UnityFramework.framework`
Starting with Unity 2019.3+, iOS builds split executable binaries into two Mach-O files:
1. `Payload/MonumentValley.app/MonumentValley` (~50 KB) — lightweight AppKit/UIKit entry wrapper.
2. `Payload/MonumentValley.app/Frameworks/UnityFramework.framework/UnityFramework` (~45 MB) — compiled IL2CPP C++ routines, engine runtime, assets, and physics.

Retagging only the root binary caused dyld platform mismatch aborts when attempting to load `UnityFramework`.

### 3.2. IL2CPP Runtime Crash on `dictionaryRepresentation`
The game saves chapter progress through iCloud KVS. Unity 2020's save implementation invokes:
```objc
NSDictionary *dict = [[NSUbiquitousKeyValueStore defaultStore] dictionaryRepresentation];
```
Early `NSUbiquitousKeyValueStore` mocks lacked this selector, causing IL2CPP to abort with:
```text
-[NSUbiquitousKeyValueStore dictionaryRepresentation]: unrecognized selector sent to instance 0x10...
*** Terminating app due to uncaught exception 'NSInvalidArgumentException'
```

---

## 4. Applied Mitigations

### 4.1. Recursive `UnityFramework.framework` Retagging
`engine/patch_app.py` recursively detects `UnityFramework` and applies `vtool`:
```bash
vtool -set-build-version maccatalyst 14.0 14.0 -replace \
    -output Payload/MonumentValley.app/Frameworks/UnityFramework.framework/UnityFramework \
    Payload/MonumentValley.app/Frameworks/UnityFramework.framework/UnityFramework
```

### 4.2. Extended `NSUbiquitousKeyValueStore` Mock (`ubiquitous_store.m`)
Implemented `dictionaryRepresentation`:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static CFMutableDictionaryRef s_ubiDict = NULL;

static id hook_dictionaryRepresentation(id self, SEL _cmd) {
    if (!s_ubiDict) return [NSDictionary dictionary];
    return (__bridge id)s_ubiDict;
}

__attribute__((constructor))
static void init_ubiquitous_dictionary_fix(void) {
    Class cls = objc_getClass("NSUbiquitousKeyValueStore");
    if (!cls) return;

    Method m = class_getInstanceMethod(cls, sel_registerName("dictionaryRepresentation"));
    if (m) {
        method_setImplementation(m, (IMP)hook_dictionaryRepresentation);
    } else {
        class_addMethod(cls, sel_registerName("dictionaryRepresentation"), 
                        (IMP)hook_dictionaryRepresentation, "@@:");
    }
}
```

### 4.3. 9:16 Window Profile
Enforces `540x960` with `aspect_fit` scaling, preserving isometric perspective lines.

---

## 5. Status & Verification

- **Status**: **Verified / 60 FPS Flawless**
- **Gameplay**: Rotating architectural mechanisms, perspective transitions, atmospheric audio, and reliable chapter progress persistence.
- **Recipe File**: `recipes/com.ustwo.monumentvalley.ini`

```ini
[metadata]
name = Monument Valley
bundle_id = com.ustwo.monumentvalley
tested_version = 2.10.2
engine = unity_il2cpp
rendering = metal
sound_system = unity_coreaudio

[window]
width = 540
height = 960
aspect_ratio = 9:16
resizable = true
orientation = portrait
scale_mode = aspect_fit

[shims]
ubiquitous_store = true
ubiquitous_dictionary_representation = true
frameworks_retag = UnityFramework.framework
assert_suppress = true
keychain = in_memory
path_redirect = documents
activation_policy = regular
```
