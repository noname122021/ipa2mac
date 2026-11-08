# ipa2mac

> **Convert non-encrypted ARM64 iOS applications (IPAs) into standalone native macOS applications running under SIP.**

[![macOS](https://img.shields.io/badge/macOS-12.0%2B%20%7C%20Apple%20Silicon-black?logo=apple&style=flat-square)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64-blue?style=flat-square)](#)
[![iOS Target](https://img.shields.io/badge/iOS-7.0%2B%20(ARM64)-purple?style=flat-square)](#)
[![Security](https://img.shields.io/badge/SIP-Enabled%20(100%25%20Stock)-brightgreen?style=flat-square)](#)
[![Engine](https://img.shields.io/badge/Catalyst-Native%20ABI-orange?style=flat-square)](#)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

**ipa2mac** is an open-source conversion engine and execution framework that transforms non-encrypted 64-bit iOS application packages (`.ipa`) into native macOS application bundles (`.app`). It runs directly on Apple Silicon bare metal via Apple's native Mac Catalyst runtime subsystem (`LC_BUILD_VERSION platform 6`) paired with declarative, modular micro-shims (`libshim.dylib`).

Unlike jailbreak-era loaders, virtual machines, or SIP-bypassing wrappers, **ipa2mac** operates **100% within macOS System Integrity Protection (SIP)** with **zero kernel extensions**, **no root privileges**, and **native 60+ FPS Metal/OpenGL hardware acceleration**.

Available as an interactive double-clickable script (**`ipa2mac.command`**) and a scriptable CLI utility.

---

## Key Features

- 🛡️ **Zero SIP Bypass**: Works out of the box on standard, locked-down macOS installations with System Integrity Protection fully enabled. No `csrutil disable`, no boot arguments, no NVRAM manipulation.
- ⚡ **Bare-Metal Apple Silicon Performance**: No QEMU, no hypervisors, no Rosetta translation overhead. Binaries execute natively on Apple Silicon CPU cores with direct access to Apple Metal and OpenGL ES hardware contexts.
- 🪟 **No Terminal Required for Converted Apps**: Produces standalone, self-contained macOS `.app` bundles that launch directly from Finder, Dock, Spotlight, or Launchpad with their original application icon and high-DPI scaling.
- 🧩 **Modular Micro-Shims (`libshim.dylib`)**: Non-invasive dynamic runtime adaptation through dyld interposing and Objective-C swizzling. Shims intercept iOS-specific behaviors (missing `MPMoviePlayerController`, Game Center authentication loops, in-memory Keychain persistence, CoreAudio thread prioritization) without altering application logic.
- 📐 **Declarative Window & Aspect-Ratio Locking**: Overcomes macOS WindowServer constraints (minimum titlebar widths, CAEAGLLayer distortion) using declarative aspect-fit scaling and touch coordinate remapping.
- 🧠 **Heuristic Engine Detection**: Automatically identifies common game engines and frameworks (Unreal Engine 3, Unity Mono/IL2CPP, Cocos2d-x, Skiko Compose Multiplatform, PopCap, Native UIKit/Swift) and selects tailored compatibility profiles.
- 📋 **Declarative Recipe Catalog**: Over 15 verified, ready-to-run recipes in `recipes/<bundle_id>.ini` with version tracking and inheritance support.

---

## Where ipa2mac fits in the iOS on Mac Ecosystem

Running iOS applications on macOS spans different historical eras and execution techniques. Here is where **ipa2mac** fits among existing community solutions:

- **iOS 1.0 – 6.1 (Legacy 32-bit ARMv7)**: Apple Silicon chips physically lack hardware support for the 32-bit ARM instruction set (AArch32). Running classic 32-bit legacy titles requires a CPU instruction emulator with JIT, such as [touchHLE](https://github.com/touchHLE/touchHLE) or [HULUS](https://github.com/HULUS-Emulator/HULUS).
- **[PlayCover](https://github.com/PlayCover/PlayCover)**: A prominent community solution tailored primarily for keyboard and mouse mapping in modern games (e.g., Genshin Impact), historically designed to operate with System Integrity Protection (SIP) disabled or lowered, often leveraging MobileSubstrate and dynamic tweak injection.
- **ipa2mac**: Focuses on **100% native execution without emulation under fully enabled SIP** for 64-bit applications (iOS 7.0 – iOS 18+) through Apple's official Mac Catalyst subsystem (`LC_BUILD_VERSION platform 6`). It produces standalone, self-contained `.app` bundles requiring no root privileges, no SIP bypasses, and no external daemon loaders.

---

## How It Works

**ipa2mac** transforms iOS binaries into native Mac Catalyst applications through a surgical 4-stage pipeline:

```mermaid
flowchart LR
    A["Non-Encrypted iOS .ipa"] --> B["1. Unpack & Validate"]
    B --> C["2. Mach-O Retagging (vtool)"]
    C --> D["3. LC_LOAD_DYLIB Shim Injection"]
    D --> E["4. Info.plist & Ad-Hoc Signing"]
    E --> F["Native macOS .app"]
```

### 1. Unpack & DRM Validation
`ipa2mac` extracts the `.ipa` archive, locates the payload `.app` bundle, thins the binary to `arm64` if fat, and inspects the Mach-O load commands for `LC_ENCRYPTION_INFO` / `LC_ENCRYPTION_INFO_64`. Only non-encrypted binaries are processed; encrypted App Store binaries are safely rejected with actionable remediation instructions.

### 2. Mach-O Platform Retagging
Because Apple Silicon Macs share the exact 64-bit ARM instruction set with modern iOS devices, the binary does not need emulation. Instead, `ipa2mac` updates the Mach-O `LC_BUILD_VERSION` load command from **iOS (`platform 2`)** to **Mac Catalyst (`platform 6`)** using Apple's native `vtool`:
```bash
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output Binary Binary
```
This transformation is applied recursively to the main executable, embedded dynamic frameworks (`.framework`), and shared dynamic libraries (`.dylib`).

### 3. Shim Injection (`LC_LOAD_DYLIB`)
`ipa2mac` copies `libshim.dylib` directly into the application bundle and binds it into the Mach-O header via an `@executable_path/libshim.dylib` load command. During dynamic linker bootstrap, `libshim` hooks early initialization to resolve platform discrepancies:
- **Device Model Spoofing**: Sysctl `hw.machine` returned as `iPad8,1` or `iPad7,1` so legacy engines activate high-fidelity rendering profiles.
- **Audio Session & Deadlock Neutralization**: Suppresses legacy `fishhook` conflicts during `_dyld_register_func_for_add_image` and frees CoreAudio worker threads from throttling.
- **Missing Framework Fallbacks**: Supplies mock implementations for retired iOS APIs (e.g., `MPMoviePlayerController`, `GKLocalPlayer` async handler, `NSUbiquitousKeyValueStore`).
- **Filesystem Remapping**: Transparently reroutes sandbox documents and fixed-path assumptions (e.g. `/tmp/SwordGame.app`) to maintain clean macOS sandbox etiquette.

### 4. Info.plist Fixups & Ad-Hoc Signing
The bundle metadata is aligned with macOS Catalyst standards:
- Injects `CFBundleSupportedPlatforms = ["MacOSX"]`.
- Sets `UIDeviceFamily = [2]` (iPad layout preference).
- Strips quarantine extended attributes (`xattr -cr`).
- Performs ad-hoc deep code signing (`codesign -f -s - --deep`) to satisfy gatekeeper runtime requirements under SIP.

---

## Quick Start

### Prerequisites

> [!IMPORTANT]
> **Supported Applications: iOS 7.0 and higher (64-bit ARM64 only)**
>
> Apple Silicon processors physically lack 32-bit execution mode (ARMv7). The 64-bit `arm64` architecture was introduced to the iOS ecosystem starting with **iOS 7.0** on the Apple A7 processor (iPhone 5s). Consequently, legacy 32-bit-only iOS applications (iOS 6 and earlier, or packages lacking an arm64 slice) cannot run on Apple Silicon hardware without full CPU emulation.

- Mac with **Apple Silicon** (M1 / M2 / M3 / M4 or newer).
- macOS Monterey (12.0) or higher (tested up to macOS Sonoma and Sequoia).
- macOS Command Line Tools installed:
  ```bash
  xcode-select --install
  ```
- System Integrity Protection (SIP) can remain **fully enabled**.

### Installation & Build

Clone the repository and compile the native micro-shim:

```bash
git clone <repository-url>
cd ipa2mac
chmod +x ipa2mac.command engine/*.sh
./engine/build_shim.sh
```

### Option A: Double-Click in Finder (Interactive)

1. Double-click **`ipa2mac.command`** directly in Finder.
2. A Terminal window will open prompting:
   ```text
   =================================================
              ipa2mac — iOS to Mac Converter         
   =================================================

   Drag and drop your non-encrypted 64-bit .ipa file here:
   (or paste the file path and press Enter)
   >
   ```
3. Drag and drop your `.ipa` file into the Terminal window and hit **Enter**.
4. The converted `.app` bundle is generated in the same folder as your IPA. Double-click it to run immediately!

### Option B: Terminal CLI

For automated pipelines, scripts, and terminal users:

```bash
# Convert an IPA using ipa2mac.command
./ipa2mac.command /path/to/Game.ipa

# Or directly invoke the conversion engine
./engine/patch_app.sh /path/to/Game.ipa
```

The patched application is finalized in-place and ready to launch:
```bash
open "/path/to/Game.app"
```

---

## Tested Applications & Compatibility

**ipa2mac** features an extensive, verified compatibility register. All Tier 1 targets execute at **full 60 FPS hardware speed** with sound, touch/mouse translation, and persistent game saves:

| Application | Bundle ID | Tested Version | Tech Stack | Status |
| :--- | :--- | :--- | :--- | :--- |
| **BADLAND** | `com.frogmindgames.dodge` | `3.4.3` | Frogmind C++ / Cocos2d-x | 🟢 Verified / 60 FPS |
| **LIMBO** | `com.playdeadgames.limbo.ios` | `1.1.28` | Playdead C++ Engine | 🟢 Verified / 60 FPS |
| **Monument Valley** | `com.ustwo.monumentvalley` | `2.10.2` | Unity 2020 (IL2CPP) | 🟢 Verified / 60 FPS |
| **Alto's Adventure** | `com.snowman.alto` | `1.6.2` | Unity 5.1 (Mono) | 🟢 Verified / 60 FPS |
| **Cut the Rope** | `com.zeptolab.cuttherope` | `2.7.1` | ZeptoLab C++ | 🟢 Verified / 60 FPS |
| **Infinity Blade II** | `com.chairentertainment.IB2` | `1.3.5` | Unreal Engine 3 (Mobile) | 🟢 Verified / In-Game |
| **EcoFlow** | `com.ef.EcoFlow` | `6.11.0` | Native Swift / Metal | 🟢 Verified / Working |
| **VLC for Mobile** | `org.videolan.vlc-ios` | `3.0.2` | Native Swift / libvlc | 🟢 Verified / Working |
| **GoodReader Pro** | `com.goodiware.grpro` | `5.6.1119` | Native ObjC / C++ | 🟢 Verified / Working |
| **PCalc** | `com.pcalc.mobile` | `3.7.5` | Native CocoaTouch / C | 🟢 Verified / Working |

For full technical teardowns, planned Tier 2 targets (35+ apps), and engine-specific quirks, refer to:
👉 **[Full Compatibility Matrix & Target Catalog (COMPATIBILITY.md)](COMPATIBILITY.md)**

---

## Recipe System

**ipa2mac** uses clean, human-readable INI configuration files to customize shims per application without recompiling code.

### Using Recipes

Recipes live directly in the `recipes/` directory. When patching an application, `ipa2mac` automatically checks for a matching recipe (`recipes/<bundle_id>.ini`) and bundles it into the app.

To add or customize a recipe, simply place a `<bundle_id>.ini` file into the `recipes/` folder.

### Recipe Example (`recipes/com.playdeadgames.limbo.ios.ini`)

```ini
[metadata]
name = LIMBO
bundle_id = com.playdeadgames.limbo.ios
tested_version = 1.1.28
engine = playdead_cpp
rendering = custom_metal
sound_system = fmod_coreaudio

[window]
width = 1152
height = 648
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
hardware_model = iPad8,1
game_center_auto_auth = true
keychain = in_memory
assert_suppress = true
path_redirect = documents
activation_policy = regular
```

### Adding a New Recipe & AI-Assisted Porting

Want to make an unsupported app or game work? The `docs/` directory provides ready-to-use LLM prompts and reverse engineering manuals to guide adding full support for any game or application:

1. **AI Agent Onboarding Prompt** ([`docs/AGENT_ONBOARDING_PROMPT.md`](docs/AGENT_ONBOARDING_PROMPT.md)):
   Pass this prompt to an AI coding assistant (Claude, Cursor, Copilot, ChatGPT, etc.). It equips the model with complete domain knowledge of Mac Catalyst Mach-O headers, dyld interposing, Game Center / AudioSession stubs, and the declarative recipe format. By supplying terminal error outputs or crash traces from an unsupported IPA, the assistant can diagnose missing symbols and generate a corresponding `recipes/<bundle_id>.ini` file.
2. **Reverse Engineering Field Manual** ([`docs/APP_REVERSING_PATTERNS.md`](docs/APP_REVERSING_PATTERNS.md)):
   A technical reference detailing common iOS-on-Mac roadblocks: static C++ audio session deadlocks, synchronous Game Center authentication traps, sysctl hardware spoofing, Metal touch coordinate scaling, and sandboxed file paths.

#### Submitting Your Recipe
1. Identify the app's `CFBundleIdentifier` from its `Info.plist`.
2. Create `recipes/<bundle_id>.ini` specifying required window dimensions, orientation, and shim toggles.
3. Test conversion with `ipa2mac.command`.
4. If you get it working, please **open a Pull Request** or share your recipe in **GitHub Issues**! Every submitted recipe expands out-of-the-box compatibility for the community.

---

## Reporting Issues & Unsupported Apps

If an application fails to launch, displays a black screen, freezes, or crashes, please **open an issue on GitHub**. The community and maintainers regularly triage compatibility issues and develop tailored recipes for `recipes/<bundle_id>.ini`.

When opening a compatibility report, please include:

1. **Application Information**:
   - **Bundle Identifier** (e.g., `com.developer.appname`, found inside `Info.plist`)
   - **Application Version** (e.g., `1.2.3`)
2. **Hardware & Environment**:
   - **Mac Model** (e.g., MacBook Air M1, Mac mini M2, MacBook Pro M3 Pro)
   - **macOS Version** (e.g., macOS 14.5 Sonoma, macOS 15.1 Sequoia)
3. **Logs & Diagnostics**:
   - Terminal output when executing the binary directly:
     ```bash
     "/path/to/PatchedApp.app/PatchedApp"
     ```
   - Relevant crash reports or stack traces from macOS Console (`~/Library/Logs/DiagnosticReports/`).

With this diagnostic data, missing iOS APIs, audio session deadlocks, or window constraints can be identified to construct and add a working recipe to the catalog.

---

## Project Structure

```text
├── README.md                 # Project documentation and quick start
├── LICENSE                   # MIT License (2026, ipa2mac contributors)
├── COMPATIBILITY.md          # Complete compatibility matrix and engine catalog
├── ipa2mac.command           # Double-clickable Finder script (terminal drag-and-drop)
├── engine/
│   ├── patch_app.sh          # Core CLI conversion and JIT patching engine
│   ├── build_shim.sh         # Standalone shim compilation script
│   ├── insert_dylib.py       # Mach-O LC_LOAD_DYLIB injection script
│   ├── modules/              # Clean JIT micro-shim source modules
│   └── libshim.dylib         # Compiled default micro-shim binary
├── recipes/                  # Declarative INI quirks and configuration catalog
│   ├── com.chairentertainment.IB2.ini
│   ├── com.frogmindgames.dodge.ini
│   ├── com.playdeadgames.limbo.ios.ini
│   ├── com.ustwo.monumentvalley.ini
│   └── ...
└── docs/
    ├── AGENT_ONBOARDING_PROMPT.md   # System prompt for LLM agent onboarding
    └── APP_REVERSING_PATTERNS.md    # Reverse engineering and triaging field manual
```

---

## Legal & Compliance

- **Fair Use & Interoperability**: `ipa2mac` is an open-source research and interoperability project developed under fair use principles, US Copyright Act § 1201(f) (reverse engineering for interoperability), and EU Directive 2009/24/EC.
- **DRM-Free & Non-Encrypted Software Only**: `ipa2mac` **does not bypass, crack, or remove Apple FairPlay DRM**. It will not process encrypted IPA binaries downloaded directly from the iOS App Store. Users must provide their own legitimately acquired, non-encrypted arm64 application packages.
- **Trademarks**: iOS, macOS, Mac Catalyst, Apple Silicon, Metal, and Finder are trademarks of Apple Inc. All game titles, application names, and brand assets are property of their respective copyright holders. `ipa2mac` is an independent project and is not affiliated with, endorsed by, or sponsored by Apple Inc. or any third-party app publishers.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

