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
