#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void (*orig_idle)(id, SEL, BOOL) = NULL;
static void (*orig_idle_reason)(id, SEL, BOOL, id) = NULL;

static void hook_idle(id self, SEL _cmd, BOOL d) {
    if ([NSThread isMainThread]) {
        if (orig_idle) orig_idle(self, _cmd, d);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (orig_idle) orig_idle(self, _cmd, d);
    });
}

static void hook_idle_reason(id self, SEL _cmd, BOOL d, id r) {
    if ([NSThread isMainThread]) {
        if (orig_idle_reason) orig_idle_reason(self, _cmd, d, r);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (orig_idle_reason) orig_idle_reason(self, _cmd, d, r);
    });
}

__attribute__((constructor))
static void init_idle_timer(void) {
    Class c = objc_getClass("UIApplication");
    if (!c) return;
    Method m1 = class_getInstanceMethod(c, sel_registerName("setIdleTimerDisabled:"));
    if (m1) {
        orig_idle = (void (*)(id, SEL, BOOL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hook_idle);
    }
    Method m2 = class_getInstanceMethod(c, sel_registerName("_setIdleTimerDisabled:forReason:"));
    if (m2) {
        orig_idle_reason = (void (*)(id, SEL, BOOL, id))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hook_idle_reason);
    }
}
