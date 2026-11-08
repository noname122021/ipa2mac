# Case Study: Grand Theft Auto: Vice City (RenderWare & OpenAL 3D)

Authoritative case study and technical post-mortem for running GTA Vice City on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Grand Theft Auto: Vice City
- **Bundle Identifier**: `com.rockstargames.gta3vc`
- **Tested Version**: 1.5.1 (Build 1.5.1)
- **Minimum iOS Version**: iOS 5.1.1 (64-bit arm64 maintenance release)
- **Engine / Architecture**: War Drum Studios / RenderWare Custom C++
- **Graphics Backend**: Legacy OpenGL ES 2.0 / 3.0
- **Audio Stack**: OpenAL 3D Audio Engine / AudioQueue
- **Window Profile**: 16:9 Landscape (960x540 / 1280x720), Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

Grand Theft Auto: Vice City by Rockstar Games was adapted for mobile platforms by War Drum Studios for its 10th anniversary.

This case confirmed the feasibility of running early 2010s heavy C++ 3D open-world engines featuring streaming vehicle models and audio radio broadcasts under macOS Catalyst.

---

## 3. Root Cause Analysis

### 3.1. Save Game and Config Storage in Sandbox Root
War Drum Studios implements proprietary world save serialization (`save.b`) and control configs (`setting.a`). Without sandbox container write permissions, the game crashed when creating an autosave file after the opening Ocean View Hotel cutscene.

### 3.2. OpenAL Audio Device Initialization
The game uses low-level OpenAL contexts (`alcOpenDevice`, `alcCreateContext`) for hardware mixing across dozens of concurrent sound sources (engines, waves, radio stations, dialogue). When `AVAudioSession` hung in Mac Catalyst, the system audio server refused hardware device allocation, locking the app on a black screen.

### 3.3. Touch Virtual Controls
Gameplay inputs (throttle, steering, weapon selection, radio tuning) rely on touch coordinates mapped to virtual buttons.

---

## 4. Applied Mitigations

### 4.1. Platform Retagging and Shim Injection
```bash
# Retag Mach-O platform to Catalyst
vtool -set-build-version maccatalyst 14.0 14.0 -replace \
    -output apps_test/gta_vice_city/Payload/gta3vc.app/gta3vc \
    apps_test/gta_vice_city/Payload/gta3vc.app/gta3vc

# Inject LC_LOAD_DYLIB via Python utility
python3 engine/insert_dylib.py \
    apps_test/gta_vice_city/Payload/gta3vc.app/gta3vc \
    "@executable_path/libshim.dylib"
```

### 4.2. Save File Isolation via `CFFIXED_USER_HOME`
In `libshim.dylib`:
```objc
NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
setenv("CFFIXED_USER_HOME", [docPath UTF8String], 1);
```
Game saves persist reliably between sessions inside `~/Documents`.

### 4.3. Hardware Model Spoofing (`device_spoof.c`)
Spoofing `iPad8,1` via `sysctl` and `uname` enables maximum draw distance, high-resolution dynamic shadows, and enhanced lighting.

---

## 5. Status & Verification

- **Status**: **Verified / Fully Playable Open-World**
- **Gameplay**: Full world navigation, driving, shooting, all radio stations (Flash FM, Wave 103, V-Rock) streaming in stereo, mission save and reload verified.
- **Launcher Script**: `apps_test/run_gta_vice_city.command`
```bash
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$DIR/gta_vice_city/Payload/gta3vc.app"
echo "=== Launching GTA Vice City ==="
DYLD_INSERT_LIBRARIES="$APP_DIR/libshim.dylib" "$APP_DIR/gta3vc"
```
