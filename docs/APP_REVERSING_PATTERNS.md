# Reverse Engineering & Runtime Mitigation Patterns for iOS on macOS

Authoritative field manual for reverse engineering, triaging runtime crashes, and writing surgical micro-shims to adapt non-encrypted arm64 iOS binaries for Mac Catalyst on Apple Silicon.

---

## 1. Static Binary Triage & Symbol Extraction

Before running an IPA, inspect the Mach-O binary structure, dependencies, and embedded frameworks.

### Step 1: Thinning and Load Commands Inspection
```bash
# Verify Mach-O architectures (must contain arm64)
file Payload/Target.app/Target

# Thin to arm64 if FAT binary
lipo -thin arm64 Payload/Target.app/Target -output Payload/Target.app/Target

# Inspect LC_BUILD_VERSION and platform ID (platform 2 = iOS, platform 6 = Mac Catalyst)
otool -l Payload/Target.app/Target | grep -A 8 LC_BUILD_VERSION

# Retag to Mac Catalyst 14.0
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output Payload/Target.app/Target Payload/Target.app/Target

# Retag any nested dynamic frameworks (CRITICAL for Unity, VLC, Unreal Engine)
find Payload/Target.app/Frameworks -type f -perm +111 -exec vtool -set-build-version maccatalyst 14.0 14.0 -replace -output {} {} \;
```

### Step 2: String & Symbol Scraping
```bash
# Check for third-party hooked libraries (fishhook, Everyplay, GameCenter)
nm -m Payload/Target.app/Target | grep -E "_dyld_register_func_for_add_image|fishhook|Everyplay"

# Scan for device profile checks
strings -a Payload/Target.app/Target | grep -E "hw\.machine|hw\.model|iPad|iPhone|GraphicsProfile"

# Check for Key-Value Store / iCloud references
strings -a Payload/Target.app/Target | grep -E "NSUbiquitousKeyValueStore|kCFPreferences"
```

---

## 2. dyld Deadlocks & Static Initializers

### The Symptom
The application launches, creates a process, but hangs indefinitely before entering `main()` or rendering any window. LLDB backtrace shows thread 0 stuck inside `_os_trace_init_slow` or waiting on a recursive dispatch lock:
```text
* frame #0: 0x0000000180000000 in __psynch_mutexwait ()
  frame #1: 0x0000000180000120 in _os_trace_init_slow ()
  frame #2: 0x0000000180000240 in _dyld_register_func_for_add_image ()
  frame #3: 0x000000010005a200 in Target`rebind_symbols ()
```

### Root Cause
Many legacy iOS game engines (Frogmind, ZeptoLab, early Unity) embed Facebook SDK, Everyplay, or `fishhook`. `fishhook` calls `_dyld_register_func_for_add_image` during C++ static initialization (`__attribute__((constructor))`). In modern macOS dyld, this image registration lock conflicts with `libdispatch` initialization locks held during binary bootstrap, producing an unrecoverable recursive deadlock.

### Mitigation Pattern
Neutralize `_dyld_register_func_for_add_image` via `DYLD_INTERPOSE`:
```objc
#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

typedef void (*dyld_image_func)(const struct mach_header* mh, intptr_t vmaddr_slide);
static void shim_dyld_register_func_for_add_image(dyld_image_func func) {
    // No-op: suppress fishhook dynamic symbol re-binding during startup
}
DYLD_INTERPOSE(shim_dyld_register_func_for_add_image, _dyld_register_func_for_add_image);
```

---

## 3. AudioSession & CoreAudio Deadlocks

### The Symptom
Game hangs during initialization on `mach_msg_trap`, or game runs at 5 FPS with stuttering sound. In logs:
```text
[mediaserverd] Client PID xxxx failed to establish AudioSession connection.
```

### Root Cause
1. **Mach IPC in Constructors**: `AVAudioSession` relies on `mediaserverd` over Mach IPC. Calling `[AVAudioSession sharedInstance]` or `setCategory:` inside a constructor locks dyld while waiting for the daemon response.
2. **Audio IOThread Throttling**: On macOS, secondary audio threads (such as FMOD or Wwise mixing threads) without AppKit main-thread activation are throttled by the macOS scheduler as background tasks.

### Mitigation Pattern
1. Intercept `AVAudioSession` methods early and provide deterministic values:
```objc
static double hook_sampleRate(id self, SEL _cmd) { return 44100.0; }
static id hook_category(id self, SEL _cmd) { return @"AVAudioSessionCategoryPlayback"; }
static BOOL hook_setCategory(id self, SEL _cmd, id cat, ...) { return YES; }
static BOOL hook_setActive(id self, SEL _cmd, BOOL active, ...) { return YES; }
```
2. Neutralize `[AVAudioSession setDelegate:]` (required for Unreal Engine 3 games like Infinity Blade 2):
```objc
static void hook_setDelegate(id self, SEL _cmd, id d) {
    // Neutralize legacy delegate assignment that crashes under Catalyst
}
```

---

## 4. iCloud & Ubiquitous Key-Value Store (`NSUbiquitousKeyValueStore`)

### The Symptom
Crash immediately after splash screen:
```text
*** Assertion failure in -[NSUbiquitousKeyValueStore init], NSUbiquitousKeyValueStore.m:64
BUG IN CLIENT OF KVS: NSUbiquitousKeyValueStore initialized without entitlement
```
Or for Unity 2020+ IL2CPP games:
```text
-[NSUbiquitousKeyValueStore dictionaryRepresentation]: unrecognized selector sent to instance
```

### Root Cause
iOS games assume `NSUbiquitousKeyValueStore defaultStore` is always available for cloud save synching. Under Mac Catalyst without full iCloud Developer provisioning and entitlements, calling `defaultStore` aborts the host process.

### Mitigation Pattern
Provide an in-memory dictionary mock with swizzled selectors:
```objc
static CFMutableDictionaryRef g_ubiDict = NULL;

static id hook_defaultStore(id self, SEL _cmd) { return self; }
static id hook_objectForKey(id self, SEL _cmd, NSString *key) {
    if (!key || !g_ubiDict) return nil;
    return (id)CFDictionaryGetValue(g_ubiDict, (__bridge const void *)(key));
}
static void hook_setObject(id self, SEL _cmd, id obj, NSString *key) {
    if (!key || !g_ubiDict) return;
    if (obj) CFDictionarySetValue(g_ubiDict, (__bridge const void *)(key), (__bridge const void *)(obj));
    else CFDictionaryRemoveValue(g_ubiDict, (__bridge const void *)(key));
}
static id hook_dictionaryRepresentation(id self, SEL _cmd) {
    return g_ubiDict ? (__bridge id)g_ubiDict : [NSDictionary dictionary];
}
static BOOL hook_synchronize(id self, SEL _cmd) { return YES; }
```

---

## 5. Keychain & Security Framework (`SecItem*`)

### The Symptom
App crashes on first launch during device UUID or auth token generation:
```text
SecItemCopyMatching failed: -25300 (errSecItemNotFound)
SecItemAdd failed: -34018 (errSecMissingEntitlement)
```

### Root Cause
Mac Catalyst apps require the `keychain-access-groups` entitlement to access the macOS login keychain. Ad-hoc signed apps lack this entitlement, causing Security.framework to fail or abort.

### Mitigation Pattern
Interpose `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`, and `SecItemUpdate` to use an in-memory thread-safe `NSMutableDictionary`:
```objc
static NSMutableDictionary *g_keychainStore = nil;
static os_unfair_lock g_keychainLock = OS_UNFAIR_LOCK_INIT;

static OSStatus shim_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    os_unfair_lock_lock(&g_keychainLock);
    if (!g_keychainStore) g_keychainStore = [[NSMutableDictionary alloc] init];
    NSDictionary *attrs = (__bridge NSDictionary *)attributes;
    id account = attrs[(id)kSecAttrAccount] ?: attrs[(id)kSecAttrService] ?: @"default";
    id value = attrs[(id)kSecValueData] ?: attrs[(id)kSecValueRef] ?: @{};
    g_keychainStore[account] = value;
    if (result) *result = (CFTypeRef)CFBridgingRetain(value);
    os_unfair_lock_unlock(&g_keychainLock);
    return errSecSuccess;
}
DYLD_INTERPOSE(shim_SecItemAdd, SecItemAdd);
```

---

## 6. Hardware Identification & sysctl Spoofing

### The Symptom
Games like LIMBO, Real Racing, or Unreal Engine games query the machine model. On Apple Silicon, `sysctlbyname("hw.machine")` returns `"Mac14,2"` or `"Mac15,3"`. The game does not recognize the string and either:
1. Falls back to minimal 30 FPS / low-texture profile.
2. Throws an unhandled exception: `Unknown device hardware profile`.

### Mitigation Pattern
Intercept `sysctlbyname` and numeric `sysctl(CTL_HW, HW_MACHINE)` to return `"iPad8,1"` (iPad Pro 11-inch 1st gen) or `"iPhone10,6"`.
> **Crucial Rule**: Use `dladdr(__builtin_return_address(0), &info)` to filter out calls from `libdyld` so system libraries get true hardware strings:
```objc
static int shim_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    void *caller = __builtin_return_address(0);
    Dl_info dlinfo;
    if (dladdr(caller, &dlinfo) && dlinfo.dli_fname && strstr(dlinfo.dli_fname, "libdyld")) {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    if (name && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)) {
        const char *val = "iPad8,1";
        size_t len = strlen(val) + 1;
        if (oldp == NULL) { if (oldlenp) *oldlenp = len; return 0; }
        if (oldlenp && *oldlenp < len) return ENOMEM;
        strcpy((char *)oldp, val);
        if (oldlenp) *oldlenp = len;
        return 0;
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
DYLD_INTERPOSE(shim_sysctlbyname, sysctlbyname);
```

---

## 7. Window Management & WindowServer Clamps

### The 515pt Minimum Width Rule
macOS WindowServer enforces a hard minimum width restriction (~515 pt) for titled windows (`NSWindowStyleMaskTitled`). Attempting to force an iPhone 320x480 resolution directly via `[NSWindow setContentSize:]` will fail.

### The Aspect-Fit Solution (ZeptoLab / Cut the Rope Pattern)
1. Let the AppKit window be 360x540 (or 540x810).
2. Set `[window setContentAspectRatio:NSMakeSize(2.0, 3.0)]`.
3. Center the rendering layer (`CAEAGLLayer` / `CALayerHost`) using affine scale transform.
4. Hook `-[UITouch locationInView:]` and `previousLocationInView:`:
```objc
static CGPoint (*orig_locationInView)(id, SEL, id) = NULL;
static CGPoint hook_locationInView(id self, SEL _cmd, id view) {
    CGPoint pt = orig_locationInView(self, _cmd, view);
    pt.x = (pt.x - g_layerOffsetX) / g_layerScale;
    pt.y = (pt.y - g_layerOffsetY) / g_layerScale;
    return pt;
}
```

---

## 8. Memory Faults & Assert Recovery

### Non-Fatal `__assert_rtn`
Many iOS frameworks call `__assert_rtn` on missing optional services (e.g. iCloud containers). Replacing `__assert_rtn` with a safe thread termination or log suppresses crashes:
```objc
__attribute__((noreturn)) void __assert_rtn(const char *func, const char *file, int line, const char *failedexpr) {
    NSLog(@"[Shim] Handled assert in %s (%s:%d): %s", func, file, line, failedexpr);
    pthread_exit(NULL);
}
```

### KERN_PROTECTION_FAILURE on JIT / Custom Allocators
Engines using custom mmap allocators (UE3, old V8/Hermes) crash on `KERN_PROTECTION_FAILURE` when writing to pages allocated without write permissions under Catalyst hardened memory rules. Catch `SIGBUS` / `SIGSEGV` and restore `PROT_READ | PROT_WRITE`:
```objc
static void handle_memory_fault(int sig, siginfo_t *info, void *ucontext) {
    uintptr_t addr = (uintptr_t)info->si_addr;
    uintptr_t page = addr & ~0x3fff;
    mprotect((void*)page, 0x10000, PROT_READ | PROT_WRITE);
}
```
