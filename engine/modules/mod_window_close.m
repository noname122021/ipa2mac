#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void (*orig_close)(id, SEL) = NULL;
static void (*orig_close_sender)(id, SEL, id) = NULL;
static void (*orig_perform_close)(id, SEL, id) = NULL;

static void handle_window_exit(id self) {
    if (![self isKindOfClass:[NSWindow class]]) return;
    if (!([((NSWindow *)self) styleMask] & NSWindowStyleMaskTitled)) return;
    exit(0);
}

static void hook_close(id self, SEL _cmd) {
    handle_window_exit(self);
    if (orig_close) orig_close(self, _cmd);
}

static void hook_close_sender(id self, SEL _cmd, id sender) {
    handle_window_exit(self);
    if (orig_close_sender) orig_close_sender(self, _cmd, sender);
}

static void hook_perform_close(id self, SEL _cmd, id sender) {
    handle_window_exit(self);
    if (orig_perform_close) orig_perform_close(self, _cmd, sender);
}

static void swizzle_method(Class cls, SEL sel, IMP imp, const char *types, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        class_addMethod(cls, sel, imp, types);
        return;
    }
    if (orig) *orig = method_getImplementation(m);
    if (!class_addMethod(cls, sel, imp, types)) {
        method_setImplementation(m, imp);
    }
}

__attribute__((constructor))
static void init_window_close(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        handle_window_exit([n object]);
    }];

    Class winCls = objc_getClass("NSWindow");
    if (!winCls) return;
    swizzle_method(winCls, sel_registerName("close"), (IMP)hook_close, "v@:", (IMP *)&orig_close);
    swizzle_method(winCls, sel_registerName("_close:"), (IMP)hook_close_sender, "v@:@", (IMP *)&orig_close_sender);
    swizzle_method(winCls, sel_registerName("performClose:"), (IMP)hook_perform_close, "v@:@", (IMP *)&orig_perform_close);
}
