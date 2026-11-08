#import <AppKit/AppKit.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void init_input_context(void) {
    Class vCls = objc_getClass("NSView");
    if (!vCls) return;
    IMP nilImp = imp_implementationWithBlock(^id(id s){ return nil; });
    Method m1 = class_getInstanceMethod(vCls, sel_registerName("_inputContext"));
    if (m1) method_setImplementation(m1, nilImp);
    Method m2 = class_getInstanceMethod(vCls, sel_registerName("inputContext"));
    if (m2) method_setImplementation(m2, nilImp);
}
