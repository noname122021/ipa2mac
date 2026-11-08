#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL shim_GK_isAuth(id self, SEL _cmd) { return YES; }

static void shim_GK_setAuth(id self, SEL _cmd, id h) {
    if (h) {
        void (^b)(id, NSError *) = [h copy];
        dispatch_async(dispatch_get_main_queue(), ^{ b(nil, nil); });
    }
}

static void swizzle(Class cls, SEL orig, IMP imp, const char *types) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, orig);
    if (m) method_setImplementation(m, imp);
    else class_addMethod(cls, orig, imp, types);
}

__attribute__((constructor))
static void init_gamecenter_module(void) {
    Class gk = objc_getClass("GKLocalPlayer");
    if (gk) {
        swizzle(gk, sel_registerName("isAuthenticated"), (IMP)shim_GK_isAuth, "B@:");
        swizzle(gk, sel_registerName("setAuthenticateHandler:"), (IMP)shim_GK_setAuth, "v@:@?");
    }
}
