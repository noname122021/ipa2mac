#import <Foundation/Foundation.h>
#import <MacTypes.h>
#import <objc/runtime.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

extern OSStatus AudioSessionGetProperty(UInt32 inID, UInt32 *ioDataSize, void *outData);
extern OSStatus AudioSessionSetProperty(UInt32 inID, UInt32 inDataSize, const void *inData);
extern OSStatus AudioSessionSetActive(Boolean active);
extern OSStatus AudioSessionInitialize(CFRunLoopRef inRunLoop, CFStringRef inRunLoopMode, void *inInterruptionListener, void *inClientData);

static OSStatus my_AudioSessionGetProperty(UInt32 inID, UInt32 *ioDataSize, void *outData) {
    if (!outData || !ioDataSize) return 0;
    if (*ioDataSize == sizeof(Float64)) {
        *(Float64 *)outData = 44100.0;
        return 0;
    }
    if (*ioDataSize >= sizeof(UInt32)) {
        *(UInt32 *)outData = 1;
    }
    return 0;
}

static OSStatus my_AudioSessionSetProperty(UInt32 inID, UInt32 inDataSize, const void *inData) {
    return 0;
}

static OSStatus my_AudioSessionSetActive(Boolean active) {
    return 0;
}

static OSStatus my_AudioSessionInitialize(CFRunLoopRef inRunLoop, CFStringRef inRunLoopMode, void *inInterruptionListener, void *inClientData) {
    return 0;
}

DYLD_INTERPOSE(my_AudioSessionGetProperty, AudioSessionGetProperty);
DYLD_INTERPOSE(my_AudioSessionSetProperty, AudioSessionSetProperty);
DYLD_INTERPOSE(my_AudioSessionSetActive, AudioSessionSetActive);
DYLD_INTERPOSE(my_AudioSessionInitialize, AudioSessionInitialize);

static double hook_sampleRate(id self, SEL _cmd) { return 44100.0; }
static id hook_initForMacOS(id self, SEL _cmd) { return self; }
static BOOL hook_true(id self, SEL _cmd, ...) { return YES; }
static BOOL hook_false(id self, SEL _cmd) { return NO; }
static id hook_category(id self, SEL _cmd) { return @"AVAudioSessionCategoryPlayback"; }
static id hook_mode(id self, SEL _cmd) { return @"AVAudioSessionModeDefault"; }
static NSUInteger hook_categoryOptions(id self, SEL _cmd) { return 0; }
static unsigned int hook_opaqueSessionID(id self, SEL _cmd) { return 10001; }
static NSTimeInterval hook_duration(id self, SEL _cmd) { return 0.02; }
static NSInteger hook_twoChannels(id self, SEL _cmd) { return 2; }

static void *hook_privateGetGuard(id self, SEL _cmd) {
    static char dummy_guard[128] = {0};
    return (void *)dummy_guard;
}

static void install_audio_hooks(Class cls, const char **names, IMP *imps, size_t count) {
    for (size_t i = 0; i < count; i++) {
        SEL sel = sel_registerName(names[i]);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            method_setImplementation(m, imps[i]);
            continue;
        }
        class_addMethod(cls, sel, imps[i], "@@:");
    }
}

__attribute__((constructor(-50)))
static void init_audio_early(void) {
    Class cls = objc_getClass("AVAudioSession");
    if (!cls) return;

    static const char *names[] = {
        "initForMacOS", "privateGetGuardOfImplementation", "createSessionInServer",
        "recreateSessionInServerIfNecessary", "setPlayState:error:", "setPlayState:",
        "sampleRate", "preferredSampleRate", "category", "mode", "categoryOptions",
        "isInputAvailable", "isOtherAudioPlaying", "opaqueSessionID",
        "preferredIOBufferDuration", "IOBufferDuration",
        "setPreferredIOBufferDuration:error:", "setPreferredSampleRate:error:",
        "setCategory:error:", "setCategory:withOptions:error:",
        "setCategory:mode:options:error:", "setActive:error:",
        "setActive:withOptions:error:", "outputNumberOfChannels"
    };
    static IMP imps[] = {
        (IMP)hook_initForMacOS, (IMP)hook_privateGetGuard, (IMP)hook_true,
        (IMP)hook_true, (IMP)hook_true, (IMP)hook_true,
        (IMP)hook_sampleRate, (IMP)hook_sampleRate, (IMP)hook_category,
        (IMP)hook_mode, (IMP)hook_categoryOptions, (IMP)hook_false,
        (IMP)hook_false, (IMP)hook_opaqueSessionID, (IMP)hook_duration,
        (IMP)hook_duration, (IMP)hook_duration, (IMP)hook_true,
        (IMP)hook_true, (IMP)hook_true, (IMP)hook_true,
        (IMP)hook_true, (IMP)hook_true, (IMP)hook_twoChannels
    };

    install_audio_hooks(cls, names, imps, sizeof(names) / sizeof(names[0]));
}
