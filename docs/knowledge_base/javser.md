# Case Study: JAVser (Compose Multiplatform & AVFoundation)

Authoritative case study and technical post-mortem for running JAVser on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: JAVser
- **Bundle Identifier**: `com.guro.javser`
- **Tested Version**: 1.0.0
- **Minimum iOS Version**: iOS 16.0
- **Engine / Architecture**: Compose Multiplatform (Kotlin/Native)
- **Graphics Backend**: Skiko / Metal
- **Audio & Video Stack**: AVFoundation (`AVPlayer`, `AVPlayerLayer`, `CoreMedia`)
- **Window Profile**: Free / Aspect Unlocked, Resizable (`900x700`, `scale_mode = native`)

---

## 2. Context & Chronology

JAVser is a modern iOS application (iOS 16+) built on **Kotlin Multiplatform + Jetpack Compose for iOS**, using **Skiko (Metal)** for UI rendering and **AVFoundation** for network video playback.

This case highlighted the hazards of global shimming and established the zero-leakage, recipe-isolated shim architecture.

---

## 3. Root Cause Analysis

### 3.1. Missing BackgroundTasks Symbols (`_OBJC_CLASS_$_BGContinuedProcessingTaskRequest`)
On startup, dyld failed with an unresolved dynamic symbol:
```text
dyld: Symbol not found: _OBJC_CLASS_$_BGContinuedProcessingTaskRequest
  Referenced from: /Payload/JAVser.app/JAVser
  Expected in: /System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks
```
iOS 16 introduced `BGContinuedProcessingTaskRequest`, which was absent from macOS Catalyst 14.0 `BackgroundTasks.framework`.

### 3.2. Network Video Playback Freeze (`AVPlayer`)
While the Compose UI rendered normally, video playback froze at 00:00 with an infinite buffering spinner:
1. **Audio Session Corruption**: Unconditional early `AVAudioSession` stubs returning dummy `opaqueSessionID = 10001` prevented `CoreMedia` from synchronizing its master timebase against `mediaserverd`.
2. **Framework Collision**: Blindly redirecting `BackgroundTasks.framework` to `libshim.dylib` caused duplicate class warnings (`Class BGTaskScheduler is implemented in both...`), breaking asset decoders.
3. **Suppressed dyld Callbacks**: Global no-op interposing of `_dyld_register_func_for_add_image` prevented `VideoToolbox` dynamic decoder registration (`VTVideoDecoder`).

---

## 4. Applied Mitigations

### 4.1. Recipe Isolation (Zero-Leakage Shims)
Strictly separated legacy game workarounds from modern media APIs. In `engine/patch_app.py`, `AVAudioSession` interposing is gated exclusively behind `audio_session_fix = true`. JAVser leaves the native audio session unhooked.

### 4.2. Objective-C BackgroundTasks Stubs (`mod_bg_classes.m`)
Provided lightweight class stubs without redirecting unaffected system symbols:

```objc
#import <Foundation/Foundation.h>

@interface BGContinuedProcessingTask : NSObject @end
@implementation BGContinuedProcessingTask @end

@interface BGContinuedProcessingTaskRequest : NSObject @end
@implementation BGContinuedProcessingTaskRequest @end

@interface BGTaskRequest : NSObject @end
@implementation BGTaskRequest @end

@interface BGAppRefreshTaskRequest : BGTaskRequest @end
@implementation BGAppRefreshTaskRequest @end

@interface BGProcessingTaskRequest : BGTaskRequest @end
@implementation BGProcessingTaskRequest @end
```

### 4.3. Selective Framework Redirection in `patch_app.py`
`patch_app.py` inspects binaries and only redirects `BackgroundTasks.framework` via `install_name_tool` when `background_tasks_redirect = true` is explicitly specified in the recipe.

### 4.4. Pass-Through dyld Callbacks
`dyld_fishhook_suppress.c` only suppresses image registration when `dyld_fishhook_suppress = true`. In all other cases, calls transparently pass to `libdyld`, preserving VideoToolbox hardware acceleration.

---

## 5. Status & Verification

- **Status**: **Verified / Fully Working**
- **UI / UX**: Jetpack Compose rendered cleanly via Skiko/Metal, smooth list scrolling, hardware-accelerated H.264/HEVC streaming video with synchronized audio.
- **Recipe File**: `recipes/com.guro.javser.ini`

```ini
[metadata]
name = JAVser
bundle_id = com.guro.javser
tested_version = 1.0.0
engine = compose_multiplatform_kotlin_native
rendering = skiko_metal
sound_system = avfoundation

[window]
width = 900
height = 700
aspect_ratio = free
resizable = true
orientation = free
scale_mode = native

[shims]
keychain = in_memory
activation_policy = regular
window_styling = true
window_close_exit = true
path_redirect = documents
background_tasks_redirect = true
```
