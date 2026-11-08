# Case Study: VLC for Mobile (Multi-Framework Retagging & LibVLC)

Authoritative case study and technical post-mortem for running VLC for Mobile on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: VLC for Mobile
- **Bundle Identifier**: `org.videolan.vlc-ios`
- **Tested Version**: 3.0.2 (Build 303)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: Native Swift & Objective-C / `libvlc` C Engine
- **Graphics Backend**: UIKit / Metal / OpenGL ES (Video Output Layer)
- **Audio Stack**: CoreAudio / AudioUnit
- **Window Profile**: Free / Aspect Unlocked, Resizable (`960x600`, `scale_mode = native`)

---

## 2. Context & Chronology

VLC for Mobile is an open-source media player supporting nearly all audio and video formats without prior transcoding.

This case prompted the recursive traversal and retagging of embedded dynamic frameworks and dylibs across complex iOS app bundles.

---

## 3. Root Cause Analysis

### 3.1. dyld Platform Mismatch on Embedded Frameworks (`wrong platform`)
Initially, platform conversion only touched the main executable `Payload/VLC for iOS.app/VLC for iOS`. However, VLC packages dynamic frameworks inside `Frameworks/`:
- `MobileVLCKit.framework` (libvlc engine, FFmpeg decoders, demuxers)
- `MediaLibraryKit.framework` (local media indexing)

On launch, dyld immediately aborted:
```text
dyld: Library not loaded: @rpath/MobileVLCKit.framework/MobileVLCKit
  Referenced from: /Payload/VLC for iOS.app/VLC for iOS
  Reason: mach-o, but wrong platform (expected 6 [Mac Catalyst], got 2 [iOS])
```

### 3.2. Invalid Dynamic Library Signatures (`Code Signature Invalid`)
Modifying Mach-O platform headers inside embedded frameworks invalidated their signatures, causing the macOS kernel to reject loading them into the process address space.

---

## 4. Applied Mitigations

### 4.1. Recursive Mach-O Retagging in `patch_app.py`
`patch_app.py` recursively traverses the app bundle, locates all nested dynamic libraries, thins them to `arm64`, and retags each Mach-O header:
```bash
# Handled automatically in patch_app.py for every embedded framework
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output "$TARGET" "$TARGET"
```

### 4.2. Hierarchical Bottom-Up Ad-Hoc Signing
Codesigns individual nested dynamic libraries first, then `.framework` bundles, and finally the top-level application bundle (`codesign -f -s - --deep`).

---

## 5. Status & Verification

- **Status**: **Verified / Fully Working Media Player**
- **Capabilities**: Hardware-accelerated media decoding (MKV, MP4, AVI) via libvlc, free window resizing with responsive video layer scaling, and CoreAudio multi-channel audio output.
- **Recipe File**: `recipes/org.videolan.vlc-ios.ini`

```ini
[metadata]
name = VLC for Mobile
bundle_id = org.videolan.vlc-ios
tested_version = 3.0.2
engine = native_swift_libvlc
rendering = uikit_metal_opengl
sound_system = coreaudio_audiounit

[window]
width = 960
height = 600
aspect_ratio = free
resizable = true
orientation = free
scale_mode = native

[shims]
multi_framework_retag = MobileVLCKit.framework,MediaLibraryKit.framework
network_entitlements = true
keychain = in_memory
path_redirect = documents
activation_policy = regular
window_styling = true
window_close_exit = true
```
