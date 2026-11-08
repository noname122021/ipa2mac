# Case Study: Plants vs. Zombies HD (PopCap 4:3 Fixed iPad Grid)

Authoritative case study and technical post-mortem for running Plants vs. Zombies HD on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Plants vs. Zombies HD
- **Bundle Identifier**: `com.popcap.PvZiPad`
- **Tested Version**: 1.9.12 (Build 4134)
- **Minimum iOS Version**: iOS 7.0 (64-bit arm64 maintenance release)
- **Engine / Architecture**: PopCap SexyAppFramework (C++ Mobile Port)
- **Graphics Backend**: Legacy OpenGL ES 2.0
- **Audio Stack**: OpenAL / AudioToolbox
- **Window Profile**: Fixed 4:3 iPad Aspect Ratio (1024x768), Non-Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

Plants vs. Zombies HD by PopCap Games is a tower defense classic designed around the 9.7-inch display of the original iPad.

This case established the pattern for adapting grid-based 2D strategies with rigid tile-coordinate matrices.

---

## 3. Root Cause Analysis

### 3.1. Lawn Grid Coordinate Distortion on Arbitrary Resizing
SexyAppFramework determines tile columns (0–8) and rows (0–4) using strict integer math:
```c
int col = (touch_x - LAWN_OFFSET_X) / CELL_WIDTH;
int row = (touch_y - LAWN_OFFSET_Y) / CELL_HEIGHT;
```
Allowing arbitrary resizing or widescreen aspect ratios misaligned mouse click coordinates: plants were placed multiple tiles offset, and falling sun pickups could not be collected.

### 3.2. Legacy AudioToolbox Looping
PopCap executes sound sample looping via `AudioServicesPlaySystemSound` and OpenAL buffers, requiring valid audio playback session categorization without crashing under Catalyst.

---

## 4. Applied Mitigations

### 4.1. Enforcing Fixed 4:3 Dimensions (1024x768)
Disallowed arbitrary resizing (`resizable = false`) and configured `scale_mode = aspect_fit` with display centering. This guarantees pixel-accurate correspondence between mouse inputs and the tile coordinate matrix.

### 4.2. Platform Retagging & Shim Injection
```bash
# Retag to Mac Catalyst 14.0
vtool -set-build-version maccatalyst 14.0 14.0 -replace \
    -output apps_test/pvz_hd/Payload/PvZHD.app/PvZHD \
    apps_test/pvz_hd/Payload/PvZHD.app/PvZHD

# Inject libshim.dylib
python3 engine/insert_dylib.py \
    apps_test/pvz_hd/Payload/PvZHD.app/PvZHD \
    "@executable_path/libshim.dylib"
```

### 4.3. Profile and Level Save Persistence
Redirecting user profile storage (`users.dat`) into `~/Documents` ensures campaign progression, coins, and Almanac unlocks persist reliably across launches.

---

## 5. Status & Verification

- **Status**: **Verified / 60 FPS Classic Perfection**
- **Gameplay**: Mouse clicks place plants precisely in target grid cells, sun pickups collect smoothly, zombie waves advance with original audio effects, and minigames (Vasebreaker, I, Zombie) function completely.
- **Launcher Script**: `apps_test/run_pvz_hd.command`
```bash
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$DIR/pvz_hd/Payload/PvZHD.app"
echo "=== Launching Plants vs. Zombies HD ==="
DYLD_INSERT_LIBRARIES="$APP_DIR/libshim.dylib" "$APP_DIR/PvZHD"
```
