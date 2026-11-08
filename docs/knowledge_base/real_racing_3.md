# Case Study: Real Racing 3 (Firemonkeys Mint 3 Engine)

Authoritative case study and technical post-mortem for running Real Racing 3 on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Real Racing 3
- **Bundle Identifier**: `com.ea.realracing3.inc`
- **Tested Version**: 14.0.1 (Modified ipa.store release)
- **Minimum iOS Version**: iOS 11.0
- **Engine / Architecture**: Firemonkeys Mint 3 Engine (Proprietary C++ / Metal, 64-bit arm64)
- **Graphics Backend**: Apple Metal (Native M-series Silicon)
- **Audio Stack**: CoreAudio / FMOD / OpenAL
- **Window Profile**: 16:9 Landscape (1280x720), Resizable (`scale_mode = aspect_fit`)
- **Spoofed Device Profile**: `iPad6,7` (iPad Pro 12.9" Wi-Fi)

---

## 2. Context & Chronology

Real Racing 3 is an industry-standard mobile racing simulator featuring highly detailed track environments, realistic vehicle physics, and high-density polyhedral car models.

The test target utilized a modified ipa.store distribution paired with an offline asset archive (`Caches_ipastore.zip`, ~5.7 GB) containing tracks, textures, shaders, and vehicles. Without this cache, the game attempts to download assets from decommissioned or blocked CDN endpoints.

Initial execution succeeded through the launch screen and the birth-year verification prompt, but crashed immediately upon proceeding to the introductory Laguna Seca race. Once resolved, the game stalled at the initial driving tutorial requiring device tilting.

---

## 3. Offline Cache Deployment (~5.7 GB Assets)

Because converted iOS apps run under standard macOS App Sandbox isolation, all local cache files reside in the user's container directory:
`~/Library/Containers/com.ea.realracing3.inc/Data/Library/Caches/`

To feed the 5.7 GB offline assets to the application:

### Option A: Direct Extraction (Terminal)
```bash
# 1. Ensure target container Library folder exists
mkdir -p ~/Library/Containers/com.ea.realracing3.inc/Data/Library

# 2. Extract Caches_ipastore.zip directly into Data/Library/ (creates Caches/)
unzip -q Caches_ipastore.zip -d ~/Library/Containers/com.ea.realracing3.inc/Data/Library/
```

### Option B: Symlink from External Drive (Zero Internal SSD Waste)
If the 5.7 GB assets are stored on an external SSD/USB drive:
```bash
mkdir -p ~/Library/Containers/com.ea.realracing3.inc/Data/Library
rm -rf ~/Library/Containers/com.ea.realracing3.inc/Data/Library/Caches
ln -s "/Volumes/YourDrive/path/to/Caches" ~/Library/Containers/com.ea.realracing3.inc/Data/Library/Caches
```

### Option C: Finder GUI Method
1. In Finder, press **`Cmd + Shift + G`** (Go to Folder).
2. Paste: `~/Library/Containers/com.ea.realracing3.inc/Data/Library/` and hit Enter.
3. Drag the unzipped **`Caches`** folder directly into this directory.

---

## 4. Root Cause Analysis

### 4.1. Post-Age-Dialog Crash (`EXC_BAD_ACCESS` at `0x100955484`)

- **Symptom**: Immediately after entering the birth year, the application terminated with `EXC_BAD_ACCESS (SIGSEGV)` at memory address `0x100955484` (`ldr w8, [x8]`).
- **Root Cause**: Real Racing 3 queries `sysctlbyname("hw.machine")` to look up hardware-specific engine profiles in `res/eds/*.plist`. On macOS host hardware without spoofing, the call returns `MacBookAir10,1`. The engine searched `res/eds/` for `MacBookAir10,1.plist`, found no match, logged `Error! Settings file loaded, but couldn't match a device!`, and defaulted internal LOD state pointers (`CAR_LOD_MAPPING_MIPMAP_OPPONENTS`) to `NULL`. At race startup, dereferencing this pointer caused an unrecoverable segmentation fault.
- **Mitigation**: Added `hardware_model = iPad6,7` and `user_interface_idiom = pad` to `recipes/com.ea.realracing3.inc.ini`. The app matched `res/eds/iPad6,7.plist` (`iPad Pro 12.9" wifi`), initialized all LOD tables correctly, and launched smoothly into 3D rendering.

### 4.2. Tutorial Tilt Steering Stall ("Tilt Device to Steer")

- **Symptom**: The introductory race launches into live 3D gameplay with audio, but halts progression on the mandatory tutorial modal *"Tilt device to steer"* (localized in RU as *"Чтобы повернуть наклоните устройство"*).
- **Root Cause**: The default control scheme relies on CoreMotion accelerometer sensors. Under macOS Catalyst / native execution, Apple Silicon desktop environments report `[CMMotionManager isAccelerometerAvailable] == NO`. Consequently, `-[CMMotionManager accelerometerData]` is skipped, returning zeroed acceleration data. The tutorial loop waits indefinitely for a non-zero lateral tilt threshold before granting control.

---

## 5. User Bypass & Control Scheme Mitigations

### 5.1. The In-Game Settings Workaround (Zero Code Addition)

A fully operational zero-code bypass was discovered by navigating through the game's menu hierarchy:
1. **Decline/Abort Initial Welcome Race**: Cancel out of the mandatory introductory race or restart into the secondary menu.
2. **Launch a Standard Race & Pause**: Begin a race and press the gear icon (Pause menu) at the top-left or top-right.
3. **Switch Control Mode**: Open **Controls / Steering Settings** and select an **On-Screen Buttons** or **Touch Steering** mode (e.g., Controls Option B or Buttons).
4. **Mouse Cursor Interaction**: Under macOS Apple Silicon native execution, the UIKit window translates desktop mouse clicks directly into standard `UITouch` events. Clicking the on-screen left and right turn buttons with the mouse cursor steers the vehicle accurately, allowing full gameplay without hardware tilt sensors.

---

## 6. Technical Roadmap for Autonomous Input Mapping

For an arcade-style desktop experience (driving with keyboard keys `A`/`D` or Left/Right arrows), two technical approaches are evaluated:

### 6.1. Option A: CoreMotion Accelerometer Synthesis (~15-20 Lines Obj-C)
- Intercept `-[CMMotionManager isAccelerometerAvailable]` to return `YES`.
- Monitor `NSEvent` key events (or swizzle `keyDown:` / `keyUp:`):
  - Holding `A` / Left Arrow sets virtual lateral acceleration `y = -0.75`.
  - Holding `D` / Right Arrow sets virtual lateral acceleration `y = +0.75`.
  - Releasing keys resets lateral acceleration `y = 0.0`.
- Return a synthetic `CMAccelerometerData` instance from `-[CMMotionManager accelerometerData]` with this acceleration vector.
- **Advantage**: Re-enables the default tilt control mode smoothly without configuring in-game menus.

### 5.2. Option B: Native GameController Emulation (`GCController`)
- Real Racing 3 imports Apple's `GameController.framework` (`_OBJC_CLASS_$_GCController`).
- Registering a virtual `GCExtendedGamepad` maps physical keyboard keys or gamepads directly into native iOS controller inputs.
