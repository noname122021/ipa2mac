# Case Study: CarX Street (Unity IL2CPP & Metal)

Authoritative case study and technical post-mortem for running CarX Street on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: CarX Street
- **Bundle Identifier**: `com.carxtech.sr`
- **Tested Version**: 1.24.0 (Build 1004)
- **Minimum iOS Version**: iOS 15.0
- **Engine / Architecture**: Unity 6000.0.64f1 (IL2CPP 64-bit)
- **Graphics Backend**: Metal (Apple M-series Silicon native GfxDevice)
- **Audio Stack**: FMOD / CoreAudio
- **Window Profile**: 16:9 Landscape (1280x720), Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

CarX Street is a high-fidelity open-world racing simulator on iOS (>3 GB client footprint, procedural night city rendering, complex tire physics simulation).

Integration verified that the Unity Metal pipeline runs stably on Apple Silicon with 93–155% CPU utilization and ~780 MB RAM.

---

## 3. Root Cause Analysis

### 3.1. Blocking Free Disk Space Verification (`statfs` / `statvfs`)
During startup, the CarX asset downloader checks available storage via POSIX `statfs` / `statvfs` and Foundation's `NSURLVolumeAvailableCapacityKey`. If available space is below an internal 64 GB threshold, initialization aborts with a storage error modal.

### 3.2. Hang on On-Demand Resources (ODR / `NSBundleResourceRequest`)
The game leverages Apple On-Demand Resources to stream vehicle models and district assets. Under Mac Catalyst without App Store daemon connectivity, `[NSBundleResourceRequest beginAccessingResourcesWithCompletionHandler:]` hangs indefinitely, deadlocking the Unity asset loading thread.

### 3.3. Missing Unity Addressables Bundle (`shared_assets_all.bundle`)
Inside `Data/Raw/aa/BuildTarget`, the Unity Addressables manager looked for `shared_assets_all.bundle`. The distribution contained `shared_prefabs_assets_all.bundle`. Without an exact filename match, Addressables threw an unhandled exception: `Addressables: Unable to load asset bundle`.

### 3.4. dyld Image Registration Deadlock (`fishhook`)
Embedded analytics and ad frameworks using `fishhook` triggered recursive lock contention in `_dyld_register_func_for_add_image`.

### 3.5. Desktop GPU Profile Degradation
Without hardware model spoofing, the engine categorized the host as a generic desktop, disabling dynamic lighting and reflection shaders.

---

## 4. Applied Mitigations

### 4.1. 64 GB Disk Space Spoofing (`statfs_spoof.m`)
Interposed filesystem statistics functions to emulate ~64 GB of free disk capacity:

```c
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/statvfs.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static int shim_statfs(const char *path, struct statfs *buf) {
    int ret = statfs(path, buf);
    if (buf) {
        buf->f_bsize = 4096;
        buf->f_blocks = 33554432;   // 128 GB total
        buf->f_bfree = 16777216;    // 64 GB free
        buf->f_bavail = 16777216;   // 64 GB available
    }
    return ret;
}
DYLD_INTERPOSE(shim_statfs, statfs);

static int shim_statvfs(const char *path, struct statvfs *buf) {
    int ret = statvfs(path, buf);
    if (buf) {
        buf->f_bsize = 4096;
        buf->f_frsize = 4096;
        buf->f_blocks = 33554432;
        buf->f_bfree = 16777216;
        buf->f_bavail = 16777216;
    }
    return ret;
}
DYLD_INTERPOSE(shim_statvfs, statvfs);
```

### 4.2. On-Demand Resources Bypass (`odr_bypass.m`)
Intercepted `NSBundleResourceRequest` selectors to immediately signal successful resource availability:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef void (^ODRCompletionBlock)(NSError * _Nullable error);

static void hook_beginAccessing(id self, SEL _cmd, ODRCompletionBlock completion) {
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
    }
}

static void hook_conditionallyBegin(id self, SEL _cmd, void (^completion)(BOOL resourcesAvailable)) {
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES);
        });
    }
}

__attribute__((constructor))
static void init_odr_bypass(void) {
    Class cls = objc_getClass("NSBundleResourceRequest");
    if (!cls) return;
    
    Method m1 = class_getInstanceMethod(cls, sel_registerName("beginAccessingResourcesWithCompletionHandler:"));
    if (m1) method_setImplementation(m1, (IMP)hook_beginAccessing);
    
    Method m2 = class_getInstanceMethod(cls, sel_registerName("conditionallyBeginAccessingResourcesWithCompletionHandler:"));
    if (m2) method_setImplementation(m2, (IMP)hook_conditionallyBegin);
}
```

### 4.3. Declarative Asset Bundle Duplication (`bundle_copy`)
Configured in `recipes/com.carxtech.sr.ini`:
```ini
bundle_copy = Data/Raw/aa/BuildTarget/shared_prefabs_assets_all.bundle:Data/Raw/aa/BuildTarget/shared_assets_all.bundle
```
`engine/patch_app.py` automatically duplicates the bundle during conversion if the destination does not exist.

### 4.4. Hardware Spoofing (`iPad13,8`)
Configuring `hardware_model = iPad13,8` (iPad Pro 11-inch 3rd gen with Apple M1) unlocks the highest fidelity Metal rendering path.

---

## 5. Status & Verification

- **Status**: **Verified / Active Process on Metal**
- **Runtime Verification**: Native GfxDevice `Apple M1` (Unity 6000.0.64f1), window sized to 1280x720, logs confirm: `disk free 65747 MB` and `Available capacity: 68941553664`.
- **Recipe File**: `recipes/com.carxtech.sr.ini`

```ini
[metadata]
name = CarX Street
bundle_id = com.carxtech.sr
tested_version = 1.24.0
engine = unity_il2cpp
rendering = metal
sound_system = fmod_coreaudio

[window]
width = 1280
height = 720
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
hardware_model = iPad13,8
statfs_spoof = true
odr_bypass = true
dyld_fishhook_suppress = true
keychain = in_memory
activation_policy = regular
bundle_copy = Data/Raw/aa/BuildTarget/shared_prefabs_assets_all.bundle:Data/Raw/aa/BuildTarget/shared_assets_all.bundle
```
