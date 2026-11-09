#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void fix_layer_host_in_layer(CALayer *layer, CGRect full) {
    for (CALayer *sub in layer.sublayers) {
        if ([sub isKindOfClass:NSClassFromString(@"CALayerHost")]) {
            layer.bounds = full;
            sub.bounds = full;
            continue;
        }
        fix_layer_host_in_layer(sub, full);
    }
}

static void fix_calayer_host_bounds(CGFloat w, CGFloat h) {
    id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
    CGRect full = CGRectMake(0, 0, w, h);
    for (id win in wins) {
        id cv = ((id (*)(id, SEL))objc_msgSend)(win, sel_registerName("contentView"));
        CALayer *root = cv ? ((id (*)(id, SEL))objc_msgSend)(cv, sel_registerName("layer")) : nil;
        if (root) fix_layer_host_in_layer(root, full);
    }
}

static void fix_overlay_views(id container) {
    if (!container) return;
    NSArray *subs = ((id (*)(id, SEL))objc_msgSend)(container, sel_registerName("subviews"));
    Class vidCls = objc_getClass("TouchableVideoView");
    Class colCls = objc_getClass("UIColor");
    id clearCol = colCls ? ((id (*)(id, SEL))objc_msgSend)(colCls, sel_registerName("clearColor")) : nil;
    for (id v in subs) {
        CALayer *l = ((id (*)(id, SEL))objc_msgSend)(v, sel_registerName("layer"));
        BOOL isVideo = vidCls && [v isKindOfClass:vidCls];
        ((void (*)(id, SEL, BOOL))objc_msgSend)(v, sel_registerName("setOpaque:"), isVideo);
        if (l) l.opaque = isVideo;
        if (!isVideo && clearCol) {
            id bg = ((id (*)(id, SEL))objc_msgSend)(v, sel_registerName("backgroundColor"));
            if (!bg) ((void (*)(id, SEL, id))objc_msgSend)(v, sel_registerName("setBackgroundColor:"), clearCol);
        }
    }
}

static void schedule_fix_loop(id container, int remaining) {
    if (remaining <= 0) return;
    fix_overlay_views(container);
    fix_calayer_host_bounds(1280, 720);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        schedule_fix_loop(container, remaining - 1);
    });
}

static void (*orig_sendTouchEvents)(id, SEL, id, int, BOOL) = NULL;

static void hook_sendTouchEvents(id self, SEL _cmd, id touches, int type, BOOL allowMismatch) {
    if (!touches) return;
    NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(touches, sel_registerName("count"));
    if (count == 0) return;
    if (orig_sendTouchEvents) orig_sendTouchEvents(self, _cmd, touches, type, YES);
}

static int (*orig_getFingerId)(id, SEL, id, int, BOOL) = NULL;

static int hook_getFingerId(id self, SEL _cmd, id touch, int type, BOOL allowMismatch) {
    if (orig_getFingerId) return orig_getFingerId(self, _cmd, touch, type, YES);
    return -1;
}

static void (*orig_setupVideoView)(id, SEL, id) = NULL;

static void hook_setupVideoView(id self, SEL _cmd, id containerView) {
    if (orig_setupVideoView) orig_setupVideoView(self, _cmd, containerView);
    id app = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    NSArray *wins = app ? ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows")) : nil;
    Class colCls = objc_getClass("NSColor");
    id blackCol = colCls ? ((id (*)(id, SEL))objc_msgSend)(colCls, sel_registerName("blackColor")) : nil;
    for (id w in wins) {
        if (blackCol) ((void (*)(id, SEL, id))objc_msgSend)(w, sel_registerName("setBackgroundColor:"), blackCol);
    }
    schedule_fix_loop(containerView, 60);
}

static void hook_method(Class cls, const char *sel_name, IMP hook, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel_registerName(sel_name));
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

__attribute__((constructor))
static void init_genshin_cloud_fix(void) {
    Class cCore = objc_getClass("ClientCoreObjc");
    if (cCore) hook_method(cCore, "setupVideoView:", (IMP)hook_setupVideoView, (IMP *)&orig_setupVideoView);
    Class vView = objc_getClass("TouchableVideoView");
    if (vView) {
        hook_method(vView, "sendTouchEvents:withType:allowMismatch:", (IMP)hook_sendTouchEvents, (IMP *)&orig_sendTouchEvents);
        hook_method(vView, "getFingerId:withType:allowMismatch:", (IMP)hook_getFingerId, (IMP *)&orig_getFingerId);
    }
}
