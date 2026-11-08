#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface DummyEveryplay : NSObject
@end

@implementation DummyEveryplay
+ (id)sharedInstance { return nil; }
+ (void)initWithDelegate:(id)d andParentViewController:(id)vc {}
+ (BOOL)isSupported { return NO; }
+ (void)startRecording {}
+ (void)stopRecording {}
@end

static void stub_everyplay_methods(void) {
    Class ep = objc_getClass("Everyplay");
    if (ep) {
        Method m = class_getClassMethod(ep, sel_registerName("initWithDelegate:andParentViewController:"));
        if (m) method_setImplementation(m, [DummyEveryplay methodForSelector:@selector(initWithDelegate:andParentViewController:)]);
    }
    Class epSurf = objc_getClass("EveryplaySurfaceGlEs");
    if (epSurf) {
        Method m2 = class_getInstanceMethod(epSurf, sel_registerName("resizeBuffer:"));
        if (m2) method_setImplementation(m2, imp_implementationWithBlock(^{}));
    }
}

__attribute__((constructor))
static void init_everyplay_module(void) {
    stub_everyplay_methods();
}
