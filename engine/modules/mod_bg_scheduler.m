#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void init_bg_scheduler(void) {
    if (objc_getClass("BGTaskScheduler")) return;
    Class cls = objc_allocateClassPair(objc_getClass("NSObject"), "BGTaskScheduler", 0);
    if (!cls) return;
    Class meta = object_getClass((id)cls);
    id (^sharedBlk)(id) = ^id(id selfCls) {
        static id s;
        static dispatch_once_t o;
        dispatch_once(&o, ^{ s = [objc_getClass("BGTaskScheduler") new]; });
        return s;
    };
    class_addMethod(meta, sel_registerName("sharedScheduler"), imp_implementationWithBlock(sharedBlk), "@@:");

    BOOL (^regBlk)(id, NSString *, dispatch_queue_t, id) = ^BOOL(id selfObj, NSString *ident, dispatch_queue_t q, id handler) {
        return YES;
    };
    class_addMethod(cls, sel_registerName("registerForTaskWithIdentifier:usingQueue:launchHandler:"), imp_implementationWithBlock(regBlk), "B@:@@@?");

    BOOL (^subBlk)(id, id, NSError **) = ^BOOL(id selfObj, id req, NSError **err) {
        return YES;
    };
    class_addMethod(cls, sel_registerName("submitTaskRequest:error:"), imp_implementationWithBlock(subBlk), "B@:@^@");

    objc_registerClassPair(cls);
}
