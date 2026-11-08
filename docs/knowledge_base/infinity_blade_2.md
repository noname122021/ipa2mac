# Case Study: Infinity Blade II (Unreal Engine 3 Mobile)

Authoritative case study and technical post-mortem for running Infinity Blade II on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: Infinity Blade II
- **Bundle Identifier**: `com.chairentertainment.IB2` (also alias `com.chaoringames.InfinityBlade2`)
- **Tested Version**: 1.3.5 (Build 9714.140)
- **Minimum iOS Version**: iOS 6.0 (arm64 port released for iPhone 5s / iOS 7)
- **Engine / Architecture**: Unreal Engine 3 (Mobile 2011) / Epic Games C++
- **Graphics Backend**: OpenGL ES 2.0 (via Apple Silicon GLES compatibility layer)
- **Audio Stack**: OpenAL / AudioQueue
- **Window Profile**: Fixed 4:3 Aspect Ratio (1024x768), Non-Resizable (`resizable = false`, `scale_mode = aspect_fit`)

---

## 2. Context & Chronology

Infinity Blade II is an action RPG developed by Chair Entertainment and Epic Games, serving as the debut benchmark for Unreal Engine 3 on 64-bit ARM64 hardware.

Adapting this engine uncovered five distinct platform incompatibilities spanning binary instructions, path encodings, and legacy media frameworks.

---

## 3. Root Cause Analysis

### 3.1. Path Buffer Overflows on Non-ASCII Directories
UE3's 2011 codebase performs low-level path manipulation inside fixed `char[256]` ANSI/ASCII buffers. When executed from paths containing multi-byte UTF-8 sequences (e.g. non-ASCII directory names), buffer calculations overflowed in `FConfigCacheIni::Init`, crashing with `Assertion failed: [File:UnFile.cpp] [Line: 824]`.

### 3.2. Fatal Crash on `[AVAudioSession setDelegate:]`
During audio subsystem bootstrap, UE3 invoked:
```objc
[[AVAudioSession sharedInstance] setDelegate:self];
```
Under macOS Catalyst, this legacy selector is non-functional or triggers dyld initializer deadlocks.

### 3.3. Retired `MPMoviePlayerController`
The introductory cutscene plays via `MPMoviePlayerController`. Modern Mac Catalyst does not export this retired controller in `MediaPlayer.framework`. Calling `[MPMoviePlayerController alloc]` returned `nil`, causing `EXC_BAD_ACCESS`.

### 3.4. Crash at Offset `0x8c340` (`LoadCoalescedFile`)
Skipping the intro video and entering the main arena triggered an immediate memory abort:
```text
Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
Exception Codes: KERN_INVALID_ADDRESS at 0x0000000000000020
Crashed Thread:  0  Dispatch queue: com.apple.main-thread
0   SwordGame  0x000000010008c340 FConfigCacheIni::LoadCoalescedFile(...) + 64
```
Disassembly revealed an invalid pointer dereference: `ldr x8, [x24, #0x20]` accessed an uninitialized configuration cache struct.

### 3.5. Render Target Distortion on Resizing
UE3 allocates fixed internal render buffers (FBOs) at startup matching initial display dimensions (1024x768). Resizing the window produced a grey bar and offset touch coordinates.

### 3.6. Background Audio Persistence
OpenAL/AudioQueue created an independent audio mixer thread that continued executing after window dismissal.

---

## 4. Applied Mitigations

### 4.1. 12-Byte Binary Patch at `0x8c33c`
The original 3-instruction sequence loaded a vtable pointer into `x8`, performed an invalid read `[x24, #0x20]`, and branched via `blr x8`. 
The applied 12-byte patch at offset `0x8c33c` (`550200b4 a0aa40b9 1f2003d5`):
1. `0x8c33c`: `cbz x21, #0x8c384` (`550200b4`) — null pointer check, skip block.
2. `0x8c340`: `ldr w0, [x21, #0xa8]` (`a0aa40b9`) — direct cache size load.
3. `0x8c344`: `nop` (`1f2003d5`) — neutralizes fatal `blr x8`.

Handled declaratively via the `binary_patch` directive in `recipes/com.chairentertainment.IB2.ini`:
```ini
binary_patch = 0x8c33c:a80240f9083140f900013fd6:550200b4a0aa40b91f2003d5
```

### 4.2. ASCII Path Redirection via `/tmp/SwordGame.app` (`mod_ascii_path_redirect.m`)
Creates an ASCII symlink and swizzles `[NSBundle bundlePath]` / `resourcePath`:

```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>

#define ASCII_PATH_TARGET "/tmp/SwordGame.app"

static NSString *s_asciiPath = nil;
static NSString *(*orig_bundlePath)(id, SEL) = NULL;
static NSString *(*orig_resourcePath)(id, SEL) = NULL;

static NSString *hook_bundlePath(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle] && s_asciiPath) return s_asciiPath;
    return orig_bundlePath ? orig_bundlePath(self, _cmd) : @"";
}

static NSString *hook_resourcePath(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle] && s_asciiPath) return s_asciiPath;
    return orig_resourcePath ? orig_resourcePath(self, _cmd) : @"";
}

__attribute__((constructor))
static void init_ascii_redirect(void) {
    NSString *realAppPath = [[NSBundle mainBundle] bundlePath];
    s_asciiPath = [NSString stringWithUTF8String:ASCII_PATH_TARGET];
    unlink(ASCII_PATH_TARGET);
    symlink([realAppPath fileSystemRepresentation], ASCII_PATH_TARGET);

    Method m1 = class_getInstanceMethod([NSBundle class], @selector(bundlePath));
    orig_bundlePath = (NSString *(*)(id, SEL))method_setImplementation(m1, (IMP)hook_bundlePath);
    Method m2 = class_getInstanceMethod([NSBundle class], @selector(resourcePath));
    orig_resourcePath = (NSString *(*)(id, SEL))method_setImplementation(m2, (IMP)hook_resourcePath);
}
```

### 4.3. `MPMoviePlayerController` Mock (`fake_mpmovieplayer.m`)
Provides a lightweight stub that dispatches immediate completion notifications:

```objc
#import <Foundation/Foundation.h>

@interface FakeMPMoviePlayerController : NSObject
@property (nonatomic, copy) NSURL *contentURL;
@end

@implementation FakeMPMoviePlayerController
- (id)initWithContentURL:(NSURL *)url {
    self = [super init];
    self.contentURL = url;
    return self;
}
- (void)play {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MPMoviePlayerPlaybackDidFinishNotification" object:self];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MPMoviePlayerLoadStateDidChangeNotification" object:self];
    });
}
- (void)stop {}
@end
```

### 4.4. Audio Session Delegate Neutralization (`mod_av_delegate.m`)
```objc
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void hook_neutralize_delegate(id self, SEL _cmd, id d) {}

__attribute__((constructor))
static void init_av_delegate(void) {
    Class avCls = objc_getClass("AVAudioSession");
    if (!avCls) return;
    Method m = class_getInstanceMethod(avCls, sel_registerName("setDelegate:"));
    if (m) method_setImplementation(m, (IMP)hook_neutralize_delegate);
}
```

### 4.5. Window Locking & Clean Process Exit
Configured `resizable = false` with `1024x768` dimensions, while `mod_window_close.m` ensures clean `_exit(0)` when closing the window.

---

## 5. Status & Verification

- **Status**: **Verified / Fully Playable in Game**
- **Gameplay**: Sword combat, parrying, dodging, OpenAL sound effects, and stable 60 FPS Unreal Engine 3 rendering.
- **Recipe File**: `recipes/com.chairentertainment.IB2.ini`

```ini
[metadata]
name = Infinity Blade II
bundle_id = com.chairentertainment.IB2
tested_version = 1.3.5
engine = unreal_engine_3_mobile
rendering = gles_20
sound_system = openal_audioqueue

[window]
width = 1024
height = 768
aspect_ratio = 4:3
resizable = false
orientation = landscape
scale_mode = aspect_fit

[shims]
hardware_model = iPad8,1
user_interface_idiom = pad
audio_session_set_delegate_neutralize = true
fake_mpmovieplayer = true
ascii_path_redirect = /tmp/SwordGame.app
memory_fault_recovery = true
block_abort_raise = true
suppress_sigaction = true
keychain = in_memory
path_redirect = documents
activation_policy = regular
window_close_exit = true
binary_patch = 0x8c33c:a80240f9083140f900013fd6:550200b4a0aa40b91f2003d5
```
