# Case Study: Zenless Zone Zero (HoYoverse Unity & Metal)

Authoritative case study and technical post-mortem for running Zenless Zone Zero on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Zenless Zone Zero
- **Bundle Identifier**: `com.HoYoverse.Nap`
- **Tested Version**: 3.3.1
- **Minimum iOS Version**: iOS 14.0
- **Engine / Architecture**: Custom HoYoverse Unity Engine (IL2CPP 64-bit arm64)
- **Graphics Backend**: Apple Metal (High-density PBR and cel-shaded rendering pipeline)
- **Audio & Video Stack**: Audiokinetic Wwise / CriWare CriMana video decoder
- **Window Profile**: 16:9 Landscape (1280x720), Resizable (`scale_mode = aspect_fit`)

---

## 2. Context & Chronology

Zenless Zone Zero is HoYoverse's flagship urban fantasy action RPG, demanding high computational throughput for its fast-paced combat, real-time post-processing, and multi-gigabyte asset streaming architecture.

Under standard Mac Catalyst execution, modern AAA mobile titles often experience hangs during the initial shader pre-caching stage, audio subsystem deadlocks during video playback, or authentication stalls when querying iOS-specific security daemons.

Testing confirmed that with `ipa2mac`, Zenless Zone Zero successfully launches, completes user authentication, streams cutscene assets via CriMana, and progresses into live 3D gameplay.

---

## 3. Technical Analysis & Runtime Behaviors

### 3.1. Initial Shader PSO Compilation Delay
- **Symptom**: On the initial cold launch, the application creates a window with a black or static frame for approximately 20–30 seconds before rendering the HoYoverse splash screen.
- **Root Cause**: The Metal graphics pipeline compiles hundreds of complex compute and fragment shaders into pipeline state objects (PSOs) tailored for Apple Silicon GPU cores. On mobile iOS, these are partially pre-compiled during OS installation or App Store distribution.
- **Resolution**: No patch required; allow the one-time PSO compilation to complete. Subsequent launches utilize the Metal binary archive cache, launching in under 3 seconds.

### 3.2. Audio & Video Synchronization (Wwise + CriWare)
- **Symptom**: Multimedia engines on macOS can stall if audio clock callbacks become desynchronized from the display link during pre-rendered video playback.
- **Root Cause**: CriMana video streaming relies on continuous hardware audio clock progress from CoreAudio. In environments with heavy audio session interception or non-standard buffer configurations, video frames freeze while audio continues.
- **Resolution**: Clean passthrough of CoreAudio interfaces without legacy iOS audio session throttling, allowing CriMana and Wwise to negotiate hardware sample rates natively.

### 3.3. Authentication Token Persistence (`core_keychain.c`)
- **Symptom**: Without in-memory keychain interposition, HoYoverse account login sessions fail to persist across restarts or fail with `errSecItemNotFound (-25300)` / `errSecMissingEntitlement (-34018)`.
- **Resolution**: Enabled `core_keychain = true` in `recipes/com.HoYoverse.Nap.ini`, preserving session tokens and device identifiers across launches.

---

## 4. Operational Status & Configuration

The application operates stably under the following configuration in `recipes/com.HoYoverse.Nap.ini`:

```ini
[metadata]
name = Zenless Zone Zero
bundle_id = com.HoYoverse.Nap
tested_version = 3.3.1
engine = unity
rendering = metal
sound_system = wwise_criware

[window]
width = 1280
height = 720
aspect_ratio = 16:9
resizable = true
orientation = landscape
scale_mode = aspect_fit

[shims]
core_keychain = true
mod_window = true
mod_window_close = true
mod_input_context = true
activation_policy = regular
```

- **Authentication**: Fully working (login dialogs, token storage).
- **Audio & Video**: Fully working (voice acting, ambient BGM, CriWare cutscenes).
- **Gameplay**: Verified in-game at native 60 FPS on Apple Silicon.
