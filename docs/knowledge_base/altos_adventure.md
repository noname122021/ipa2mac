# Case Study: Alto's Adventure (Unity 5 & iCloud Key-Value Store Mock)

Authoritative case study and technical post-mortem for running Alto's Adventure on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Alto's Adventure
- **Bundle Identifier**: `com.snowman.alto`
- **Tested Version**: 1.6.2 (Build 2)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: Unity 5.1.4f1 (64-bit arm64)
- **Graphics Backend**: Apple Metal Pipeline
- **Audio Stack**: Unity CoreAudio
- **Window Profile**: 16:9 Landscape (960x540), Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

Alto's Adventure by Snowman is an atmospheric procedural snowboarding game built on an early 64-bit version of Unity 5.

This case served as the primary validation for in-memory iCloud Key-Value Store (KVS) emulation in an un-entitled runtime environment.

---

## 3. Root Cause Analysis

### 3.1. Fatal Assertion in iCloud KVS
Immediately after the Snowman logo, the game aborted with a system assertion:
```text
*** Assertion failure in -[NSUbiquitousKeyValueStore init], NSUbiquitousKeyValueStore.m:64
BUG IN CLIENT OF KVS: NSUbiquitousKeyValueStore initialized without entitlement
Abort trap: 6
```
**Cause**: When initializing save management, Unity 5 attempts to sync distances, coins, and characters via `[NSUbiquitousKeyValueStore defaultStore]`. Under Mac Catalyst, invoking this API without a paid Apple Developer identity and the `com.apple.developer.ubiquity-kvstore-identifier` entitlement raises an unrecoverable `SIGABRT`.

### 3.2. Premature Process Exit on Mouse-Up
During single clicks (jumping), AppKit event dispatching interpreted the `mouseUp` event as closing a modal context, triggering an application shutdown.

---

## 4. Applied Mitigations

### 4.1. In-Memory Mock for `NSUbiquitousKeyValueStore` (`ubiquitous_store.m`)
Swizzled `defaultStore`, `objectForKey:`, `stringForKey:`, `longLongForKey:`, `setObject:forKey:`, and `synchronize`, retaining key-value pairs in a static `CFMutableDictionaryRef`:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static CFMutableDictionaryRef s_ubiDict = NULL;

static id hook_defaultStore(id self, SEL _cmd) { 
    return self; 
}

static id hook_objectForKey(id self, SEL _cmd, NSString *key) {
    if (!key || !s_ubiDict) return nil;
    return (id)CFDictionaryGetValue(s_ubiDict, (__bridge const void *)(key));
}

static void hook_setObject(id self, SEL _cmd, id obj, NSString *key) {
    if (!key || !s_ubiDict) return;
    if (obj) {
        CFDictionarySetValue(s_ubiDict, (__bridge const void *)(key), (__bridge const void *)(obj));
    } else {
        CFDictionaryRemoveValue(s_ubiDict, (__bridge const void *)(key));
    }
}

static id hook_stringForKey(id self, SEL _cmd, NSString *key) { 
    return hook_objectForKey(self, _cmd, key); 
}

static long long hook_longLongForKey(id self, SEL _cmd, NSString *key) {
    id val = hook_objectForKey(self, _cmd, key);
    return [val respondsToSelector:@selector(longLongValue)] ? [val longLongValue] : 0;
}

static BOOL hook_synchronize(id self, SEL _cmd) { 
    return YES; 
}

__attribute__((constructor))
static void init_ubiquitous_store(void) {
    s_ubiDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    Class cls = objc_getClass("NSUbiquitousKeyValueStore");
    if (!cls) return;

    Method m = class_getClassMethod(cls, sel_registerName("defaultStore"));
    if (m) method_setImplementation(m, (IMP)hook_defaultStore);

    Method m_inst = class_getInstanceMethod(cls, sel_registerName("objectForKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_objectForKey);
    m_inst = class_getInstanceMethod(cls, sel_registerName("stringForKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_stringForKey);
    m_inst = class_getInstanceMethod(cls, sel_registerName("longLongForKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_longLongForKey);
    m_inst = class_getInstanceMethod(cls, sel_registerName("setObject:forKey:"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_setObject);
    m_inst = class_getInstanceMethod(cls, sel_registerName("synchronize"));
    if (m_inst) method_setImplementation(m_inst, (IMP)hook_synchronize);
}
```

### 4.2. Mouse-Up Event Protection (`window_close_guard`)
Filtered spurious mouse-up close triggers during gameplay inputs (jumps and backflips).

---

## 5. Status & Verification

- **Status**: **Verified / 60 FPS Solid**
- **Gameplay**: Procedural day/night cycle, weather storms, coin collection, tricks across chasms, spacebar and mouse click controls, full session progress retention.
- **Recipe File**: `recipes/com.snowman.alto.ini`

```ini
[metadata]
name = Alto's Adventure
bundle_id = com.snowman.alto
tested_version = 1.6.2
engine = unity_5
rendering = metal
sound_system = unity_coreaudio

[window]
width = 960
height = 540
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
ubiquitous_store = true
window_close_guard = true
keychain = in_memory
assert_suppress = true
path_redirect = documents
activation_policy = regular
```
