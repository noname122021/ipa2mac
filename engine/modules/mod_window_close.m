#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void (*orig_close)(id, SEL) = NULL;
static void (*orig_close_sender)(id, SEL, id) = NULL;
static void (*orig_perform_close)(id, SEL, id) = NULL;

#ifndef MOD_WINDOW_CLOSE_IMMEDIATE_EXIT
#define MOD_WINDOW_CLOSE_IMMEDIATE_EXIT 0
#endif

// Recipe: [mod_window_close] immediate_exit = true. For Catalyst games where the X button only hides the
// window (scene goes to background) and exit() deadlocks in the game's atexit/static destructors:
// the window's close button is retargeted to _exit(0) and every other window close (Cmd+Q, Cmd+W) also uses
// _exit(0), so it quits immediately. Minimize is untouched.
#if MOD_WINDOW_CLOSE_IMMEDIATE_EXIT
@interface IPA2MacCloseTarget : NSObject
@end
@implementation IPA2MacCloseTarget
- (void)quit:(id)sender { _exit(0); }
@end

static void retarget_close_button(NSWindow *w) {
    static IPA2MacCloseTarget *target;
    if (!target) target = [IPA2MacCloseTarget new];
    if (!(w.styleMask & NSWindowStyleMaskTitled)) return;
    NSButton *b = [w standardWindowButton:NSWindowCloseButton];
    if (b.target == target) return;
    b.target = target;
    b.action = @selector(quit:);
}
#endif

static void handle_window_exit(id self) {
    if (![self isKindOfClass:[NSWindow class]]) return;
    if (!([((NSWindow *)self) styleMask] & NSWindowStyleMaskTitled)) return;
#if MOD_WINDOW_CLOSE_IMMEDIATE_EXIT
    _exit(0);   // Cmd+Q / Cmd+W also end here; exit() would run the game's hanging static destructors
#else
    exit(0);
#endif
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
#if MOD_WINDOW_CLOSE_IMMEDIATE_EXIT
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification]) {
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            retarget_close_button([n object]);
        }];
    }
#endif
    [nc addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        handle_window_exit([n object]);
    }];

    Class winCls = objc_getClass("NSWindow");
    if (!winCls) return;
    swizzle_method(winCls, sel_registerName("close"), (IMP)hook_close, "v@:", (IMP *)&orig_close);
    swizzle_method(winCls, sel_registerName("_close:"), (IMP)hook_close_sender, "v@:@", (IMP *)&orig_close_sender);
    swizzle_method(winCls, sel_registerName("performClose:"), (IMP)hook_perform_close, "v@:@", (IMP *)&orig_perform_close);
}
