#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>

static CGPoint (*orig_locInView)(id, SEL, id) = NULL;

static CGPoint hook_locInView(id self, SEL _cmd, id view) {
    if (orig_locInView) {
        CGPoint pt = orig_locInView(self, _cmd, view);
        return pt;
    }
    return CGPointZero;
}

__attribute__((constructor))
static void init_touch_remap(void) {
    Class touchCls = objc_getClass("UITouch");
    if (!touchCls) return;
    Method m = class_getInstanceMethod(touchCls, sel_registerName("locationInView:"));
    if (m && !orig_locInView) {
        orig_locInView = (CGPoint (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_locInView);
    }
}
