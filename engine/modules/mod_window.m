#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#ifndef TARGET_WIDTH
#define TARGET_WIDTH 900.0
#endif
#ifndef TARGET_HEIGHT
#define TARGET_HEIGHT 700.0
#endif
#ifndef RESIZABLE
#define RESIZABLE 1
#endif

static NSSize calculate_window_size(CGFloat targetW, CGFloat targetH, NSScreen *scr) {
    NSRect visible = scr ? [scr visibleFrame] : NSMakeRect(0, 0, 1440, 900);
    CGFloat maxH = visible.size.height - 60.0;
    if (targetH > maxH && targetH > 0) {
        CGFloat scale = maxH / targetH;
        return NSMakeSize(floor(targetW * scale), floor(maxH));
    }
    return NSMakeSize(targetW, targetH);
}

static void configure_window_style(NSWindow *w, NSSize sz, BOOL resizable) {
    NSWindowStyleMask mask = [w styleMask] | NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    if (resizable) {
        [w setStyleMask:mask | NSWindowStyleMaskResizable];
        [w setMinSize:NSMakeSize(200, 200)];
        [w setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
#if defined(ASPECT_W) && defined(ASPECT_H)
        [w setContentAspectRatio:NSMakeSize(ASPECT_W, ASPECT_H)];
#endif
    } else {
        [w setStyleMask:mask & ~NSWindowStyleMaskResizable];
        [w setMinSize:sz];
        [w setMaxSize:sz];
        [w setContentMinSize:sz];
        [w setContentMaxSize:sz];
    }
    [w setContentSize:sz];
    [w setIsVisible:YES];
    [w makeKeyAndOrderFront:nil];
    [w center];
}

static void style_all_windows(void) {
    for (NSWindow *w in [NSApp windows]) {
        if (!([w styleMask] & NSWindowStyleMaskTitled)) continue;
        NSSize sz = calculate_window_size(TARGET_WIDTH, TARGET_HEIGHT, [w screen] ?: [NSScreen mainScreen]);
        configure_window_style(w, sz, RESIZABLE);
    }
}

static void schedule_sync_after(double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        style_all_windows();
    });
}

static void schedule_window_sync(void) {
    style_all_windows();
    double delays[] = {0.1, 0.3, 0.6, 1.0, 1.5, 2.5};
    for (size_t i = 0; i < sizeof(delays)/sizeof(delays[0]); i++) {
        schedule_sync_after(delays[i]);
    }
}

static void setup_environment(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.catalyst.game";
    NSString *appHome = [NSString stringWithFormat:@"%@/Library/Containers/%@/Data", NSHomeDirectory(), bid];
    NSString *docPath = [appHome stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:docPath withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("CFFIXED_USER_HOME", [appHome UTF8String], 1);
}

static void swizzle_method(Class cls, SEL orig, IMP imp, const char *types) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, orig);
    if (m) method_setImplementation(m, imp);
    else class_addMethod(cls, orig, imp, types);
}

#if defined(HOOK_UISCREEN)
static CGRect hook_bounds(id self, SEL _cmd) {
    for (NSWindow *w in [NSApp windows]) {
        if (!([w styleMask] & NSWindowStyleMaskTitled)) continue;
        NSSize s = w.contentView.bounds.size;
        if (s.width > 0 && s.height > 0) return CGRectMake(0, 0, s.width, s.height);
    }
    return CGRectMake(0, 0, TARGET_WIDTH, TARGET_HEIGHT);
}

static void setup_screen_hooks(void) {
    Class sc = objc_getClass("UIScreen");
    if (!sc) return;
#if defined(IS_CTR)
    Method bm = class_getInstanceMethod(sc, sel_registerName("bounds"));
    if (bm) method_setImplementation(bm, imp_implementationWithBlock(^CGRect(id s){ return CGRectMake(0,0,320,480); }));
    Method nm = class_getInstanceMethod(sc, sel_registerName("nativeBounds"));
    if (nm) method_setImplementation(nm, imp_implementationWithBlock(^CGRect(id s){ return CGRectMake(0,0,640,960); }));
#else
    Method m = class_getInstanceMethod(sc, sel_registerName("bounds"));
    if (m) method_setImplementation(m, (IMP)hook_bounds);
#endif
}
#endif

static void setup_parser_and_device(void) {
    Class parser = objc_getClass("_UIApplicationInfoParser");
    if (parser) swizzle_method(parser, sel_registerName("requiresFullScreen"), imp_implementationWithBlock(^BOOL(id s){ return NO; }), "B@:");
#if defined(IDIOM_PAD)
    Class dev = objc_getClass("UIDevice");
    if (dev) swizzle_method(dev, sel_registerName("userInterfaceIdiom"), imp_implementationWithBlock(^NSInteger(id s){ return 1; }), "q@:");
#endif
}

__attribute__((constructor))
static void init_window_module(void) {
    @autoreleasepool {
        setup_environment();
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
        setup_parser_and_device();
#if defined(HOOK_UISCREEN)
        setup_screen_hooks();
#endif
        dispatch_async(dispatch_get_main_queue(), ^{ schedule_window_sync(); });
    }
}
