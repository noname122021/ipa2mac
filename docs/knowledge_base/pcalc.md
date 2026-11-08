# Case Study: PCalc (Mobile Scientific Calculator)

Authoritative case study and technical post-mortem for running PCalc on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: PCalc
- **Bundle Identifier**: `com.pcalc.mobile` (also legacy `com.tlao.pcalc`)
- **Tested Version**: 3.7.5 (Build 574)
- **Minimum iOS Version**: iOS 8.0
- **Engine / Architecture**: Native CocoaTouch / Objective-C & C
- **Graphics Backend**: UIKit / CoreGraphics
- **Audio Stack**: System Audio (`AudioToolbox`)
- **Window Profile**: Free / Aspect Unlocked, Resizable (`scale_mode = native`)

---

## 2. Context & Chronology

PCalc served as the foundational proof-of-concept for the `ipa2mac` runtime architecture.

The objective was to validate the core thesis: non-encrypted (`cryptid = 0`) 64-bit ARM64 iOS binaries run natively on Apple Silicon under Mac Catalyst (`LC_BUILD_VERSION platform 6`) with targeted micro-shims without CPU emulation or disabling SIP.

---

## 3. Root Cause Analysis

### 3.1. AMFI Platform Enforcement (`SIGKILL (CODESIGN)`)
macOS kernel-level AMFI rejects executing Mach-O binaries marked with iOS platform (`PLATFORM_IOS` = 2 in `LC_BUILD_VERSION`), terminating execution immediately with `SIGKILL`.

### 3.2. Crash on Keychain Queries (`errSecMissingEntitlement -34018`)
On first launch, PCalc caches installation UUIDs and theme configurations in the iOS Keychain via `SecItemCopyMatching` and `SecItemAdd`. Under Mac Catalyst, macOS login keychain access requires the `keychain-access-groups` entitlement. Ad-hoc signed binaries lack this entitlement, causing Security.framework to return `-34018` (`errSecMissingEntitlement`), leading to an `abort()`.

### 3.3. Layout Distortion under Enforced Aspect Ratios
Global aspect-ratio enforcement (16:9 / 3:4) compressed the calculator vertically into oval buttons and clipped the calculation tape. PCalc requires unconstrained adaptive resizing (`aspect_ratio = free`).

### 3.4. Background Zombie Process on Window Close
Clicking the AppKit window close button dismissed the window from screen, but the process remained active in the background.

---

## 4. Applied Mitigations

### 4.1. Platform Header Retagging to Mac Catalyst
```bash
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output Payload/PCalc.app/PCalc Payload/PCalc.app/PCalc
```

### 4.2. In-Memory Keychain Shim (`core_keychain.c`)
Interposed Security.framework functions using a thread-safe in-memory `CFMutableDictionaryRef`:

```c
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <pthread.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static CFMutableDictionaryRef s_keychain_dict = NULL;
static pthread_mutex_t s_keychain_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

static OSStatus shim_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    pthread_mutex_lock(&s_keychain_lock);
    if (!s_keychain_dict) s_keychain_dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    const void *key = CFDictionaryGetValue(attributes, kSecAttrAccount);
    if (!key) key = CFDictionaryGetValue(attributes, kSecAttrService);
    if (!key) key = CFSTR("default");

    const void *val = CFDictionaryGetValue(attributes, kSecValueData);
    if (!val) val = CFSTR("");

    CFDictionarySetValue(s_keychain_dict, key, val);
    if (result) *result = CFRetain(val);
    pthread_mutex_unlock(&s_keychain_lock);
    return errSecSuccess;
}
DYLD_INTERPOSE(shim_SecItemAdd, SecItemAdd);
```

### 4.3. Window Close Exit Handler (`mod_window_close.m`)
Listens for `NSWindowWillCloseNotification` to cleanly terminate the process:

```objc
#import <AppKit/AppKit.h>

__attribute__((constructor))
static void init_window_close(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSWindow *w = [note object];
        if (![w isKindOfClass:[NSWindow class]] || !([w styleMask] & NSWindowStyleMaskTitled)) return;
        [NSApp terminate:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            _exit(0);
        });
    }];
}
```

### 4.4. Mach-O LC_LOAD_DYLIB Injection & Signing
`engine/patch_app.py` inserts `@executable_path/libshim.dylib` into the binary load commands and deep-signs the bundle.

---

## 5. Status & Verification

- **Status**: **Verified / Fully Working**
- **UI / UX**: Trackpad and mouse clicks supported, adaptive free-form window resizing, scientific calculation modes, persistent session state.
- **Recipe File**: `recipes/com.pcalc.mobile.ini`

```ini
[metadata]
name = PCalc
bundle_id = com.pcalc.mobile
tested_version = 3.7.5
engine = native_cocoatouch_c
rendering = uikit_coregraphics
sound_system = system_audio

[window]
aspect_ratio = free
resizable = true
scale_mode = native

[shims]
keychain = in_memory
activation_policy = regular
window_close_exit = true
path_redirect = documents
```
