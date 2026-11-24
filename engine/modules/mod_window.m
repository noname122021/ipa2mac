#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Recipe: [mod_window]
//   width, height   initial content size (points); omitted = leave the system size
//   aspect = 16:9   lock the content aspect ratio while resizing
//   resizable       default true
//   hook_screen     UIScreen.bounds follows the window content size
//   screen = WxH    UIScreen.bounds fixed to WxH (nativeBounds 2x)
//   pad_idiom       UIDevice.userInterfaceIdiom = pad
#ifndef MOD_WINDOW_RESIZABLE
#define MOD_WINDOW_RESIZABLE 1
#endif
#if defined(MOD_WINDOW_WIDTH) && defined(MOD_WINDOW_HEIGHT)
#define HAS_SIZE 1
#endif
#if MOD_WINDOW_HOOK_SCREEN || defined(MOD_WINDOW_SCREEN)
#define HOOK_UISCREEN 1
#endif

static NSSize parse_pair(const char *s, char sep) {   // "16:9" / "320x480"
    double a = 0, b = 0;
    char fmt[] = "%lf_%lf"; fmt[3] = sep;
    sscanf(s, fmt, &a, &b);
    return NSMakeSize(a, b);
}

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
#if MOD_WINDOW_HIDE_TITLEBAR
    // PlayCover style: content fills the window, only traffic lights remain
    mask |= NSWindowStyleMaskFullSizeContentView;
    [w setTitlebarAppearsTransparent:YES];
    [w setTitleVisibility:NSWindowTitleHidden];
#else
    // Catalyst sets FullSizeContentView, so games draw under the title bar
    mask &= ~NSWindowStyleMaskFullSizeContentView;
#endif
    [w setMinSize:NSMakeSize(0, 0)];
    [w setContentMinSize:NSMakeSize(0, 0)];
    if (resizable) {
        [w setStyleMask:mask | NSWindowStyleMaskResizable];
        [w setMaxSize:NSMakeSize(FLT_MAX, FLT_MAX)];
#if defined(MOD_WINDOW_ASPECT)
        [w setContentAspectRatio:parse_pair(MOD_WINDOW_ASPECT, ':')];
#endif
    } else {
        [w setStyleMask:mask & ~NSWindowStyleMaskResizable];
        [w setMaxSize:sz];
        [w setContentMaxSize:sz];
    }
    // nudge so Catalyst re-lays out the UIWindow after the style change
    [w setContentSize:NSMakeSize(sz.width, sz.height + 1)];
    [w setContentSize:sz];
    [w setIsVisible:YES];
    [w makeKeyAndOrderFront:nil];
    [w center];
}

static void style_all_windows(void) {
    for (NSWindow *w in [NSApp windows]) {
        if (!([w styleMask] & NSWindowStyleMaskTitled)) continue;
#if HAS_SIZE
        NSSize sz = calculate_window_size(MOD_WINDOW_WIDTH, MOD_WINDOW_HEIGHT, [w screen] ?: [NSScreen mainScreen]);
#else
        NSSize sz = w.contentView.bounds.size;
#if defined(MOD_WINDOW_ASPECT)
        NSSize r = parse_pair(MOD_WINDOW_ASPECT, ':');
        sz.height = round(sz.width * r.height / r.width);
#endif
#endif
        configure_window_style(w, sz, MOD_WINDOW_RESIZABLE);
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
    if ([NSHomeDirectory() hasSuffix:@"_Data"] || getenv("CFFIXED_USER_HOME")) return;
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
#if HAS_SIZE
    return CGRectMake(0, 0, MOD_WINDOW_WIDTH, MOD_WINDOW_HEIGHT);
#else
    return CGRectMake(0, 0, 1024, 768);
#endif
}

static void setup_screen_hooks(void) {
    Class sc = objc_getClass("UIScreen");
    if (!sc) return;
#if defined(MOD_WINDOW_SCREEN)
    NSSize fixed = parse_pair(MOD_WINDOW_SCREEN, 'x');
    Method bm = class_getInstanceMethod(sc, sel_registerName("bounds"));
    if (bm) method_setImplementation(bm, imp_implementationWithBlock(^CGRect(id s){ return CGRectMake(0, 0, fixed.width, fixed.height); }));
    Method nm = class_getInstanceMethod(sc, sel_registerName("nativeBounds"));
    if (nm) method_setImplementation(nm, imp_implementationWithBlock(^CGRect(id s){ return CGRectMake(0, 0, fixed.width * 2, fixed.height * 2); }));
#else
    Method m = class_getInstanceMethod(sc, sel_registerName("bounds"));
    if (m) method_setImplementation(m, (IMP)hook_bounds);
#endif
}
#endif

static void setup_parser_and_device(void) {
    Class parser = objc_getClass("_UIApplicationInfoParser");
    if (parser) swizzle_method(parser, sel_registerName("requiresFullScreen"), imp_implementationWithBlock(^BOOL(id s){ return NO; }), "B@:");
#if MOD_WINDOW_PAD_IDIOM
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
