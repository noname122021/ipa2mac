#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void hook_beginAccessingResources(id self, SEL _cmd, void (^completionHandler)(NSError *)) {
    if (completionHandler) {
        completionHandler(nil);
    }
}

static void hook_conditionallyBeginAccessingResources(id self, SEL _cmd, void (^completionHandler)(BOOL)) {
    if (completionHandler) {
        completionHandler(YES);
    }
}

static void hook_endAccessingResources(id self, SEL _cmd) {}

static void swizzle_method(Class cls, SEL sel, IMP imp, const char *types) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        method_setImplementation(m, imp);
    } else {
        class_addMethod(cls, sel, imp, types);
    }
}

__attribute__((constructor))
static void init_odr_bypass(void) {
    Class odrCls = objc_getClass("NSBundleResourceRequest");
    if (!odrCls) return;
    swizzle_method(odrCls, sel_registerName("beginAccessingResourcesWithCompletionHandler:"), (IMP)hook_beginAccessingResources, "v@:@?");
    swizzle_method(odrCls, sel_registerName("conditionallyBeginAccessingResourcesWithCompletionHandler:"), (IMP)hook_conditionallyBeginAccessingResources, "v@:@?");
    swizzle_method(odrCls, sel_registerName("endAccessingResources"), (IMP)hook_endAccessingResources, "v@:");
}
