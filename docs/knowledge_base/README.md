# ipa2mac Knowledge Base: iOS-to-macOS App Case Studies & Reversing Field Manual

Central knowledge base, verified case register, and reverse-engineering manual for the **ipa2mac** project.

This directory documents real-world adaptation of non-encrypted (`cryptid = 0`) 64-bit (`arm64`) iOS applications running natively on Apple Silicon (M1/M2/M3/M4) under macOS via Mac Catalyst (`LC_BUILD_VERSION platform 6`) and modular micro-shims (`libshim.dylib`).

---

## 1. Master Application Register

| Application | Bundle ID | Version | Engine / Tech Stack | Graphics / Audio | Root Cause Category | Applied Shims & Mitigations | Status | Document |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **PCalc** | `com.pcalc.mobile` | 3.7.5 | CocoaTouch / C | CoreGraphics / System | Keychain -34018, AMFI, Window Close | In-memory Keychain, Catalyst retag, Window Close exit | **Verified** | [pcalc.md](pcalc.md) |
| **JAVser** | `com.guro.javser` | 1.0.0 | Compose Multiplatform (Kotlin/Native) | Skiko Metal / AVFoundation | Missing `BGContinuedProcessingTaskRequest`, AVPlayer freeze | `mod_bg_classes` stub, gated audio session, pass-through dyld | **Verified** | [javser.md](javser.md) |
| **Infinity Blade II** | `com.chairentertainment.IB2` | 1.3.5 | Unreal Engine 3 (Mobile) | OpenGL ES 2.0 / OpenAL | Path encoding, missing MPMoviePlayer, 0x8c340 vtable crash | Binary patch at `0x8c33c`, `/tmp/SwordGame.app` redirect, fake MPMoviePlayer | **Verified** | [infinity_blade_2.md](infinity_blade_2.md) |
| **CarX Street** | `com.carxtech.sr` | 1.24.0 | Unity 6000 (IL2CPP) | Metal / FMOD CoreAudio | Disk check <64GB, ODR hang, missing Addressables bundle | 64GB `statfs` spoof, `NSBundleResourceRequest` bypass, Addressables bundle copy | **Verified** | [carx_street.md](carx_street.md) |
| **DEVICE 6** | `com.simogo.devicesix` | 1.4 | Simogo Native ObjC | UIKit GLES / System Audio | Gameplay requires physical iPad rotation | AppKit MenuBar "Rotate Device" action, orientation swizzle | **Verified** | [device_6.md](device_6.md) |
| **BADLAND** | `com.frogmindgames.dodge` | 3.4.3 | Frogmind C++ / Cocos2d-x | GLES Metal / FMOD CoreAudio | Dyld deadlocks in AudioSession & fishhook, 5 FPS throttle, PAGEZERO loop | Early audio hooks, fishhook suppress, audio unthrottle, PAGEZERO guard | **Verified** | [badland.md](badland.md) |
| **LIMBO** | `com.playdeadgames.limbo.ios` | 1.1.28 | Playdead Custom C++ | Custom Metal / FMOD CoreAudio | Unknown `hw.machine`, Game Center modal freeze | `iPad8,1` sysctl spoof with dladdr check, GKLocalPlayer auto-auth | **Verified** | [limbo.md](limbo.md) |
| **Cut the Rope** | `com.zeptolab.cuttherope` | 2.7.1 | ZeptoLab Native C++ | Legacy GLES 2.0 / OpenAL | WindowServer 515pt clamp, touch cursor coordinate mismatch | 2-level CALayerHost aspect-fit, `UITouch locationInView:` remap matrix | **Verified** | [cut_the_rope.md](cut_the_rope.md) |
| **Alto's Adventure** | `com.snowman.alto` | 1.6.2 | Unity 5.1.4f1 | Metal / Unity CoreAudio | `NSUbiquitousKeyValueStore` assert crash, mouse-up premature close | `MockUbiquitousStore` dictionary, mouse-up close guard | **Verified** | [altos_adventure.md](altos_adventure.md) |
| **GoodReader Pro** | `com.goodiware.grpro` | 5.6.1119 | Native ObjC / C++ | UIKit PDFKit / CoreAudio | Sandbox path crash on license accept, phone UI distortion | `CFFIXED_USER_HOME` to `~/Documents`, `UIUserInterfaceIdiomPad` (1) | **Verified** | [goodreader_pro.md](goodreader_pro.md) |
| **EcoFlow** | `com.ef.EcoFlow` | 6.11.0 | Native Swift / React Native | UIKit Metal / System Audio | Distorted phone cards, `UIScreen bounds` full screen 1440x900 | Forced `UIUserInterfaceIdiomPad` (1), clamped `UIScreen bounds` 3:4 | **Verified** | [ecoflow.md](ecoflow.md) |
| **VLC for Mobile** | `org.videolan.vlc-ios` | 3.0.2 | Swift / LibVLC C Engine | UIKit Metal / CoreAudio | Nested frameworks (`MobileVLCKit`, `MediaLibraryKit`) platform mismatch | Recursive `vtool` patch, bottom-up codesign, network entitlements | **Verified** | [vlc.md](vlc.md) |
| **Monument Valley** | `com.ustwo.monumentvalley` | 2.10.2 | Unity 2020 (IL2CPP) | Metal / Unity CoreAudio | `UnityFramework.framework` platform mismatch, IL2CPP KVS dictionary selector | Multi-binary `vtool`, `NSUbiquitousKeyValueStore dictionaryRepresentation` | **Verified** | [monument_valley.md](monument_valley.md) |
| **GTA Vice City** | `com.rockstargames.gta3vc` | 1.5.1 | War Drum / RenderWare | Legacy GLES / OpenAL 3D | Legacy AudioQueue, save game permissions in sandbox | Catalyst retag, in-memory keychain, `CFFIXED_USER_HOME` save sync | **Verified** | [gta_vice_city.md](gta_vice_city.md) |
| **Plants vs. Zombies HD**| `com.popcap.PvZiPad` | 1.9.12 | PopCap SexyAppFramework | Legacy GLES 2.0 / OpenAL | Arbitrary window resize ruins 4:3 1024x768 lawn grid collision | Fixed 4:3 1024x768 canvas, aspect-fit scaling, user save redirect | **Verified** | [plants_vs_zombies_hd.md](plants_vs_zombies_hd.md) |
| **Zenless Zone Zero** | `com.HoYoverse.Nap` | 3.3.1 | Unity / Custom Metal | Metal / Wwise CriWare | AVAudioSession XPC deadlock, memory fault exceptions | `audio_session_fix`, `iPad14,3` model spoof, `memory_fault_recovery` | **Verified** | [recipes/com.HoYoverse.Nap.ini](../../recipes/com.HoYoverse.Nap.ini) |

---

## 2. Platform Failure Taxonomy & Mitigation Patterns

### Pattern 1: Multi-Binary Bundles & Dynamic Frameworks
- **Symptom**: `dyld: Library not loaded: ... Reason: mach-o, but wrong platform (expected 6, got 2)`.
- **Root Cause**: Modern game engines (Unity 2019+, VLC, Unreal) place core logic inside dynamic frameworks in `Payload/App.app/Frameworks/`. Retagging only the root binary leaves nested libraries incompatible with the Mac Catalyst dyld loader.
- **Mitigation**: Recursive bundle traversal in `engine/patch_app.py`, thinning binaries to `arm64` with `lipo`, retagging all Mach-O files via `vtool -set-build-version maccatalyst 14.0 14.0 -replace`, followed by bottom-up ad-hoc signing.

### Pattern 2: dyld Initializer Deadlocks & Fishhook
- **Symptom**: Process launches, consumes 0% CPU, creates no window, thread 0 deadlocked in `__psynch_mutexwait` inside `_dyld_register_func_for_add_image`.
- **Root Cause**: Legacy SDKs (Everyplay, Facebook SDK) call `fishhook` inside `__attribute__((constructor))`. Image registration locks dyld mutexes, conflicting with macOS `libdispatch` initialization.
- **Mitigation**: Interpose `_dyld_register_func_for_add_image` in `dyld_fishhook_suppress.c` as a no-op stub (enabled via `dyld_fishhook_suppress = true`).

### Pattern 3: Audio Subsystem — Legacy Deadlocks vs. Modern AVPlayer Clock Sync
- **Symptom A**: Legacy games (BADLAND) hang waiting on Mach IPC to `mediaserverd` from constructors.
- **Symptom B**: Modern video players (JAVser) freeze at 00:00 when global `AVAudioSession` stubs are used, because `CoreMedia` cannot establish a master timebase without a valid session.
- **Mitigation**: Recipe isolation. `AVAudioSession` hooks (`opaqueSessionID = 10001`, `sampleRate = 44100`) are strictly scoped via `audio_session_fix = true` in `recipe.ini`. Native media apps keep the stock macOS `AVAudioSession`.

### Pattern 4: Sandbox, Special Paths, and Character Encoding
- **Symptom**: File access failures, `Assertion failed: [File:UnFile.cpp]`, settings not persisting.
- **Root Cause A**: Pre-2012 engines (UE3 / Infinity Blade II) operate with fixed-length ASCII path buffers and corrupt non-ASCII directory paths.
- **Root Cause B**: Lack of App Sandbox containers causes attempts to write to restricted user directories.
- **Mitigation**:
  1. Symlink app path to `/tmp/SwordGame.app` and interpose `[NSBundle bundlePath]` / `resourcePath`.
  2. Redirect `CFFIXED_USER_HOME` to `~/Documents`.

### Pattern 5: Missing iOS SDK System Symbols
- **Symptom**: `dyld: Symbol not found: _OBJC_CLASS_$_BGContinuedProcessingTaskRequest`.
- **Root Cause**: Apps targeting iOS 16/17 link against new `BackgroundTasks` interfaces absent from macOS Catalyst 14.0.
- **Mitigation**: Provide lightweight Objective-C class stubs (`mod_bg_classes.m`) and re-export `BackgroundTasks.framework` via `@executable_path/libshim.dylib`.

### Pattern 6: Unhandled iCloud KVS (`NSUbiquitousKeyValueStore`) Assertions
- **Symptom**: `BUG IN CLIENT OF KVS: NSUbiquitousKeyValueStore initialized without entitlement` or `-[NSUbiquitousKeyValueStore dictionaryRepresentation]: unrecognized selector`.
- **Root Cause**: Calling `defaultStore` without developer provisioning profile aborts host execution.
- **Mitigation**: Thread-safe in-memory mock (`ubiquitous_store.m`) backed by `CFMutableDictionaryRef`, implementing `defaultStore`, `objectForKey:`, `setObject:forKey:`, `dictionaryRepresentation`, and `synchronize`.

### Pattern 7: Hardware Identification Spoofing & Return-Address Filtering
- **Symptom**: Games detect host as `Mac14,2` and crash on profile checks or fall back to ultra-low texture presets.
- **Mitigation**: Intercept `sysctlbyname("hw.machine")` and `uname()`, returning `"iPad8,1"` or `"iPad13,8"`. Use return-address inspection via `dladdr(__builtin_return_address(0), ...)` so internal dyld calls receive true host hardware details.

### Pattern 8: WindowServer Constraints (515 pt) & Touch Remapping
- **Symptom**: Phone layouts (320x480) distort due to macOS 515 pt minimum window width rules; mouse clicks miss UI buttons.
- **Mitigation**: Container window with 2:3 aspect constraint (360x540), center rendering layer (`CALayerHost` / `CAEAGLLayer`), and interpose `-[UITouch locationInView:]` with an inverse coordinate scaling matrix.

### Pattern 9: PAGEZERO Guarding in Memory Fault Handlers
- **Symptom**: 100% CPU lockup on null pointer dereference.
- **Root Cause**: Attempting to call `mprotect(0, 0x4000, ...)` on Darwin's protected `PAGEZERO`.
- **Mitigation**: Validate fault address: if `addr < 0x4000`, reset handler to `SIG_DFL` immediately and forward exception to standard crash reporting.

---

## 3. Modular Shim Architecture (`engine/modules/`)

`ipa2mac` uses a fully modular micro-shim architecture. Individual source modules are dynamically compiled on the fly into `libshim.dylib` per application requirements:

```text
ipa2mac/engine/modules/
├── core_keychain.c           # Thread-safe in-memory keychain mock (SecItem*)
├── device_spoof.c            # iPad Pro hardware spoofing (sysctl, uname) with dladdr filter
├── statfs_spoof.m            # 64GB free disk space spoofing for asset downloaders
├── mod_window.m              # AppKit window styles, aspect-fit, regular activation policy
├── mod_window_close.m        # Clean process termination on window close ([NSApp terminate:])
├── mod_input_context.m       # NSTextInputContext crash mitigation
├── odr_bypass.m              # On-Demand Resources download bypass
├── mod_ascii_path_redirect.m # ASCII /tmp symlink redirection for older engines
├── fake_mpmovieplayer.m      # Legacy MPMoviePlayerController mock
├── mod_av_delegate.m         # Neutralizes faulty [AVAudioSession setDelegate:]
├── device_rotation_menu.m    # MenuBar item for games requiring device rotation
├── audio_session_fix.m       # Scoped AVAudioSession interceptor and audio unthrottle
├── mod_bg_classes.m          # BackgroundTasks class stubs (iOS 16+)
├── mod_bg_scheduler.m        # BGTaskScheduler stubs
├── background_tasks_redirect.m # Redirects BackgroundTasks.framework to libshim
├── dyld_fishhook_suppress.c  # fishhook symbol rebinding deadlock suppression
├── memory_fault_recovery.c   # Memory fault recovery with PAGEZERO protection
├── mod_signal_suppress.c     # Suppresses crashing sigaction handlers
├── mod_vm_protect.c          # RWX page permission guarantee for custom allocators
├── ubiquitous_store.m        # In-memory iCloud NSUbiquitousKeyValueStore mock
├── game_center_auto_auth.m   # Auto-authenticates GKLocalPlayer
├── touch_remapping.m         # Touch coordinate remapping for scaled layers
└── assert_suppress.c         # Intercepts __assert_rtn to terminate thread instead of aborting
```

---

## 4. Field Protocol for New Applications

1. **Unpack IPA**:
   `unzip Target.ipa -d /tmp/target_work`
2. **Verify Architecture**:
   `lipo -archs /tmp/target_work/Payload/*.app/<Executable>` (must include `arm64`).
3. **Check DRM Encryption**:
   `otool -l <Executable> | grep -A 4 LC_ENCRYPTION_INFO_64` (must be `cryptid = 0`).
4. **Create Recipe**:
   Create `recipes/{bundle_id}.ini` (or `{bundle_id}@{version}.ini`) specifying window dimensions and shims.
5. **Run Conversion Engine**:
   `python3 engine/patch_app.py /tmp/target_work/Payload/*.app` (or `python3 engine/patch_app.py Target.ipa`)
6. **Launch & Verify**:
   `./<Target>.app/<Executable>` or launch from Finder.
