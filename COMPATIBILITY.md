# ipa2mac: Compatibility Matrix & Target Catalog

Authoritative compatibility register for non-encrypted arm64 iOS applications executing natively on Apple Silicon macOS via Mac Catalyst platform retagging (`LC_BUILD_VERSION`) and micro-shims (`libshim.dylib`).

---

## 1. Verified & Playable Applications (Tier 1)

| Application | Bundle ID | Version | Engine / Tech Stack | Graphics | Audio Stack | Key Shims & Quirks | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Zenless Zone Zero** | `com.HoYoverse.Nap` | 3.3.1 | Unity / Metal / Wwise | Metal | Wwise / CriWare | In-memory session Keychain, Metal PSO compilation (~20s cold start), 16:9 aspect fit | **Verified / In-Game** |
| **CarX Street** | `com.carxtech.sr` | 1.24.0 | Unity 6000 (IL2CPP) | Metal | FMOD / CoreAudio | 64GB `statfs_spoof`, `odr_bypass`, `iPad13,8` spoof, Addressables bundle copy | **Verified / 60 FPS** |
| **BADLAND** | `com.frogmindgames.dodge` | 3.4.3 | Frogmind C++ / Cocos2d-x | GLES / Metal | FMOD / CoreAudio | Fishhook deadlock suppression, unthrottled CoreAudio IOThread, in-memory Keychain | **Verified / 60 FPS** |
| **LIMBO** | `com.playdeadgames.limbo.ios` | 1.1.28 | Playdead C++ Engine | Custom Metal | FMOD / CoreAudio | `sysctlbyname("hw.machine")` spoofed to `iPad8,1`, `GKLocalPlayer` async auto-auth | **Verified / 60 FPS** |
| **Monument Valley** | `com.ustwo.monumentvalley` | 2.10.2 | Unity 2020.3.21f1 (IL2CPP) | Metal | Unity CoreAudio | Multi-binary retagging (`UnityFramework.framework`), `MockUbiquitousStore` dictionary stub | **Verified / 60 FPS** |
| **Alto's Adventure** | `com.snowman.alto` | 1.6.2 | Unity 5.1.4f1 | Metal | Unity CoreAudio | `NSUbiquitousKeyValueStore` stub, AppKit mouse-up close guard | **Verified / 60 FPS** |
| **Cut the Rope** | `com.zeptolab.cuttherope` | 2.7.1 | ZeptoLab Native C++ | Legacy OpenGL ES 2.0 | OpenAL / AudioToolbox | 2-level `CALayerHost`/`CAEAGLLayer` aspect-fit matrix, `UITouch` coordinate remapping | **Verified / 60 FPS** |
| **Infinity Blade II** | `com.chairentertainment.IB2` | 1.3.5 | Unreal Engine 3 (Mobile) | OpenGL ES 2.0 | OpenAL / AudioQueue | ASCII `/tmp/SwordGame.app` path redirection, `[AVAudioSession setDelegate:]` neutralize, fake `MPMoviePlayerController` | **Verified / In-Game** |
| **DEVICE 6** | `com.simogo.devicesix` | 1.4 | Simogo Native ObjC | UIKit / GLES | System Audio | AppKit MenuBar device orientation rotation switch, 3:4 aspect clamp | **Verified / Working** |
| **EcoFlow** | `com.ef.EcoFlow` | 6.11.0 | Native Swift / ObjC | UIKit / Metal | System Audio | `UIUserInterfaceIdiomPad` (1) forced tablet layout, 3:4 window aspect clamp, Keychain stub | **Verified / Working** |
| **VLC for Mobile** | `org.videolan.vlc-ios` | 3.0.2 | Native Swift / libvlc C | UIKit / Metal / GLES | CoreAudio / AudioUnit | Multi-framework retagging (`MobileVLCKit`, `MediaLibraryKit`), network socket entitlements | **Verified / Working** |
| **GoodReader Pro** | `com.goodiware.grpro` | 5.6.1119 | Native ObjC / C++ | UIKit / PDFKit | CoreAudio | `CFFIXED_USER_HOME` redirection to `~/Documents`, `UIUserInterfaceIdiomPad` | **Verified / Working** |
| **PCalc** | `com.pcalc.mobile` | 3.7.5 | Native CocoaTouch / C | UIKit / CoreGraphics | System Audio | In-memory Keychain, tablet calculation tape view, window close exit handler | **Verified / Working** |
| **JAVser** | `com.guro.javser` | 1.0.0 | Compose Multiplatform (Kotlin) | Skiko Metal | AVFoundation | `mod_bg_classes` stubs, selective BackgroundTasks framework redirect | **Verified / Working** |
| **Real Racing 3** | `com.ea.realracing3.inc` | 14.0.1 | Firemonkeys Mint 3 | Metal | CoreAudio / FMOD | `hardware_model = iPad6,7` matches `res/eds/` profile, `user_interface_idiom = pad`, on-screen button controls | **Verified / 60 FPS** |

---

## 2. Tested Recipe Parameters Summary

| Bundle ID | Recipe File | Window (WxH) | Aspect Ratio | Resizable | Orientation | Device Model | Key Feature Flags |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `com.HoYoverse.Nap` | [recipes/com.HoYoverse.Nap.ini](recipes/com.HoYoverse.Nap.ini) | 1280x720 | 16:9 | Yes | Landscape | Default | `core_keychain`, `mod_input_context`, `mod_window`, `mod_window_close` |
| `com.carxtech.sr` | [recipes/com.carxtech.sr.ini](recipes/com.carxtech.sr.ini) | 1280x720 | 16:9 | Yes | Landscape | `iPad13,8` | `statfs_spoof`, `odr_bypass`, `bundle_copy` |
| `com.frogmindgames.dodge` | [recipes/com.frogmindgames.dodge.ini](recipes/com.frogmindgames.dodge.ini) | 960x540 | 16:9 | Yes | Landscape | `iPad8,1` | `dyld_fishhook_suppress`, `audio_unthrottle` |
| `com.playdeadgames.limbo.ios` | [recipes/com.playdeadgames.limbo.ios.ini](recipes/com.playdeadgames.limbo.ios.ini) | 1152x648 | 16:9 | Yes | Landscape | `iPad8,1` | `game_center_auto_auth`, `sysctl_spoof` |
| `com.ustwo.monumentvalley` | [recipes/com.ustwo.monumentvalley.ini](recipes/com.ustwo.monumentvalley.ini) | 540x960 | 9:16 | Yes | Portrait | Default | `ubiquitous_store`, `frameworks_retag` |
| `com.snowman.alto` | [recipes/com.snowman.alto.ini](recipes/com.snowman.alto.ini) | 960x540 | 16:9 | Yes | Landscape | Default | `ubiquitous_store`, `window_close_guard` |
| `com.zeptolab.cuttherope` | [recipes/com.zeptolab.cuttherope.ini](recipes/com.zeptolab.cuttherope.ini) | 360x540 | 2:3 | Yes | Portrait | Default | `touch_remapping`, `calayer_aspect_fit` |
| `com.chairentertainment.IB2` | [recipes/com.chairentertainment.IB2.ini](recipes/com.chairentertainment.IB2.ini) | 1024x768 | 4:3 | No | Landscape | `iPad8,1` | `ascii_path_redirect`, `fake_mpmovieplayer` |
| `com.simogo.devicesix` | [recipes/com.simogo.devicesix.ini](recipes/com.simogo.devicesix.ini) | 768x1024 | 3:4 | Yes | Portrait | Default | `device_rotation_menu`, `aspect_clamp` |
| `com.ef.EcoFlow` | [recipes/com.ef.EcoFlow.ini](recipes/com.ef.EcoFlow.ini) | 768x1024 | 3:4 | Yes | Portrait | `iPad8,1` | `user_interface_idiom = pad`, `aspect_clamp` |
| `org.videolan.vlc-ios` | [recipes/org.videolan.vlc-ios.ini](recipes/org.videolan.vlc-ios.ini) | 960x600 | Free | Yes | Free | Default | `multi_framework_retag`, `network_entitlements` |
| `com.goodiware.grpro` | [recipes/com.goodiware.grpro.ini](recipes/com.goodiware.grpro.ini) | 800x1000 | Free | Yes | Free | Default | `user_interface_idiom = pad`, `cffixed_user_home` |
| `com.pcalc.mobile` | [recipes/com.pcalc.mobile.ini](recipes/com.pcalc.mobile.ini) | 420x680 | Free | Yes | Portrait | Default | `user_interface_idiom = pad`, `window_close_exit` |
| `com.guro.javser` | [recipes/com.guro.javser.ini](recipes/com.guro.javser.ini) | 900x700 | Free | Yes | Free | Default | `background_tasks_redirect`, `reexport_bg` |
| `com.ea.realracing3.inc` | [recipes/com.ea.realracing3.inc.ini](recipes/com.ea.realracing3.inc.ini) | 1280x720 | 16:9 | Yes | Landscape | `iPad6,7` | `hardware_model = iPad6,7`, `user_interface_idiom = pad` |

---

## 3. Tier 2 Expansion Pipeline (35 Planned Targets)

| Target Name | Estimated Bundle ID | Engine / Technology | Graphics API | Target iOS | Anticipated Mitigation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Plants vs. Zombies HD** | `com.popcap.ios.PvZHD` | PopCap C++ Engine | OpenGL ES 2.0 | iOS 8.0 - 10.0 | Fixed 1024x768 iPad canvas, OpenAL audio, legacy touch mapping |
| **Infinity Blade** | `com.chaoringames.InfinityBlade` | Unreal Engine 3 (Mobile) | OpenGL ES 2.0 | iOS 7.0 - 11.0 | UE3 shader precompilation, OpenAL/AudioQueue, `iPad4,1` sysctl |
| **Infinity Blade III** | `com.chaoringames.InfinityBlade3` | UE3 / Metal | Early Metal / GLES 3 | iOS 9.0 - 12.0 | Early 64-bit Metal pipeline, KVS save sync, 60 FPS uncap quirk |
| **Dead Space iOS** | `com.ea.deadspace.inc` | EA IronMonkey Custom C++ | OpenGL ES 2.0 | iOS 7.0 - 10.0 | Fixed aspect viewport, EA activation stub, OpenAL 3D sound |
| **Angry Birds Classic** | `com.rovio.AngryBirdsClassic` | Rovio Fusion / C++ | OpenGL ES 2.0 | iOS 9.0 - 11.0 | Fixed letterbox, OpenAL / AVAudioPlayer, Game Center mock |
| **Tiny Wings** | `com.andreasilliger.tinywings` | Andreas Illiger C++ / Cocos2d-x | OpenGL ES 2.0 | iOS 8.0 - 12.0 | 60 FPS physics loop, OpenAL audio engine, Retina scaling |
| **Rayman Jungle Run** | `com.ubisoft.raymanjunglerun` | UbiArt Framework (C++) | OpenGL ES 2.0 | iOS 8.0 - 11.0 | UbiArt sprite batching, Wwise audio session, Game Center mock |
| **Grand Theft Auto III** | `com.rockstargames.gta3` | War Drum / RenderWare (C++) | GLES 2.0 / 3.0 | iOS 8.0 - 12.0 | Virtual controls to mouse/keyboard bridge, OpenAL 3D sound |
| **GTA: San Andreas** | `com.rockstargames.gtasa` | War Drum / RenderWare (C++) | Metal / GLES 3.0 | iOS 9.0 - 14.0 | 64-bit Metal shaders, touch steering translation, CoreAudio |
| **Geometry Dash** | `com.robtop.geometryjump` | Cocos2d-x 2.x/3.x (C++) | OpenGL ES 2.0 | iOS 8.0 - 14.0 | FMOD sound low-latency sync, CADisplayLink high-rate timer |
| **Minecraft: PE** | `com.mojang.minecraftpe` | Mojang Custom C++ | OpenGL ES 2.0 | iOS 8.0 - 10.0 | Fixed-function shaders, BSD sockets, sandbox Documents mount |
| **Minecraft Bedrock** | `com.mojang.minecraftpe` | Bedrock C++ Engine | Metal | iOS 10.0 - 14.0 | RenderDragon / Metal pipeline, multi-threaded asset loading |
| **The Room** | `com.FireproofStudios.TheRoom` | Unity 4.x / 5.x | GLES 2.0 / Metal | iOS 8.0 - 11.0 | Camera touch interaction, Unity Audio, early Metal fallback |
| **The Room Two** | `com.FireproofStudios.TheRoom2` | Unity 5.x | Metal / GLES 3.0 | iOS 8.0 - 12.0 | Unity KVS mock, high-res shadow maps, mouse drag remapping |
| **The Room Three** | `com.FireproofStudios.TheRoom3` | Unity 5.6 / 2017 | Metal | iOS 9.0 - 13.0 | `MockUbiquitousStore` required, Metal rendering, buffer tuning |
| **Kingdom Rush** | `com.ironhidegames.kingdomrush` | Ironhide C++ / Cocos2d | OpenGL ES 2.0 | iOS 9.0 - 13.0 | 2D sprite atlas, OpenAL sound effects, landscape aspect fit |
| **Kingdom Rush Frontiers** | `com.ironhidegames.kingdomrushfrontiers`| Ironhide C++ / Cocos2d | OpenGL ES 2.0 | iOS 9.0 - 13.0 | Touch offset remapping, Game Center suppress, in-memory Keychain |
| **Fruit Ninja Classic** | `com.halfbrick.FruitNinja` | Halfbrick Custom C++ | OpenGL ES 2.0 | iOS 8.0 - 11.0 | Fast swipe trajectory interpolation, OpenAL slice audio |
| **Jetpack Joyride** | `com.halfbrick.jetpackjoyride` | Halfbrick Custom C++ | OpenGL ES 2.0 | iOS 8.0 - 12.0 | Single touch hold/release event dispatch, Game Center mock |
| **Bad Piggies** | `com.rovio.BadPiggies` | Unity 5.x | Metal / GLES 2.0 | iOS 8.0 - 12.0 | Unity KVS stub, Box2D determinism, audio category initialization |
| **Doodle Jump** | `com.limasky.doodlejump` | Lima Sky Native C++ / UIKit | GLES 1.1 / 2.0 | iOS 7.0 - 11.0 | Accelerometer tilt translation to A/D or Arrow keys, vertical clamp |
| **Flappy Bird** | `com.dotgears.flap` | .GEARS Native C / UIKit | OpenGL ES 2.0 | iOS 7.0 - 10.0 | Strict 320x568 portrait canvas, tap-only input, AudioToolbox tones |
| **Canabalt** | `com.semiotown.canabalt` | Semi Secret / Flixel C++ | OpenGL ES 2.0 | iOS 7.0 - 10.0 | High-frequency update loop, OpenAL audio, spacebar jump binding |
| **World of Goo** | `com.2dboy.worldofgoo` | 2D BOY C++ / SDL | OpenGL ES 2.0 | iOS 8.0 - 12.0 | Multi-touch elastic physics, OpenAL 44.1kHz audio stream |
| **Super Hexagon** | `com.distractionware.superhexagon`| Terry Cavanagh / OpenFL C++| OpenGL ES 2.0 | iOS 8.0 - 12.0 | 60 FPS deterministic timing, left/right touch to Arrow keys |
| **Sword & Sworcery EP** | `com.capybaragames.sworcery` | Capybara C++ / Superbrothers | OpenGL ES 2.0 | iOS 8.0 - 11.0 | Orientation rotation locking, Jim Guthrie audio unthrottle |
| **Procreate Pocket** | `com.savageinteractive.procreate.pocket` | Native ObjC / Swift / Metal | Metal | iOS 12.0 - 15.0 | Silica metal engine, Apple Pencil pressure, sandbox redirection |
| **Documents by Readdle** | `com.readdle.ReaddleDocsIPad`| Native Swift / ObjC / C++ | UIKit / PDFKit / WebKit | iOS 11.0 - 14.0 | Embedded dynamic frameworks, Keychain storage, sandbox path fix |
| **Notion** | `notion.id` | React Native / WebKit | UIKit / Metal CoreAnimation | iOS 12.0 - 15.0 | JavaScriptCore/Hermes, WKWebView bridge, network entitlements |
| **Termius** | `com.serverauditor.serverauditor`| Native Swift / C (libssh) | UIKit / Metal | iOS 11.0 - 14.0 | PTY allocation, BSD sockets / libssh client, in-memory Keychain |
| **iDOS 2** | `com.fastintelligence.idos` | DOSBox C++ / UIKit | GLES 2.0 / Software | iOS 9.0 - 14.0 | Native Documents mount, virtual keyboard capture, SDL audio |
| **GarageBand** | `com.apple.mobilegarageband` | Apple Native (Logic Core / C++)| Metal / UIKit | iOS 12.0 - 14.0 | Real-time CoreAudio low-latency buffer graph, strict entitlements |
| **Scanner Pro** | `com.readdle.Scanner` | Native Swift / OpenCV | UIKit / CoreImage / Metal | iOS 11.0 - 14.0 | AVCaptureSession mock (static image feed), PDF export entitlements |
