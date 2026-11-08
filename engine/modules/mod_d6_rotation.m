#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void rotate_window(NSWindow *w) {
    NSRect f = [w frame];
    CGFloat temp = f.size.width;
    f.size.width = f.size.height;
    f.size.height = temp;
    [w setFrame:f display:YES animate:YES];
}

static void rotate_all_windows(void) {
    for (NSWindow *w in [NSApp windows]) {
        rotate_window(w);
    }
}

static void rotate_d6_to(NSInteger orient) {
    Class devCls = objc_getClass("UIDevice");
    if (devCls) {
        id dev = [devCls performSelector:sel_registerName("currentDevice")];
        [dev setValue:@(orient) forKey:@"orientation"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UIDeviceOrientationDidChangeNotification" object:dev];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        rotate_all_windows();
    });
}

@interface D6Rotator : NSObject @end
@implementation D6Rotator
+ (void)rotR:(id)s { rotate_d6_to(3); }
+ (void)rotL:(id)s { rotate_d6_to(4); }
+ (void)rotP:(id)s { rotate_d6_to(1); }

static NSMenuItem *make_menu_item(NSString *title, SEL action, NSString *key) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    [item setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    [item setTarget:[D6Rotator class]];
    return item;
}

+ (void)populateMenu:(NSMenu *)sub {
    [sub addItem:[NSMenuItem separatorItem]];
    [sub addItem:make_menu_item(@"Rotate Right (Landscape)", @selector(rotR:), @"r")];
    [sub addItem:make_menu_item(@"Rotate Left (Landscape)", @selector(rotL:), @"l")];
    [sub addItem:make_menu_item(@"Rotate Portrait", @selector(rotP:), @"p")];
}

static NSMenuItem *ensure_view_menu(NSMenu *main) {
    NSMenuItem *item = [main itemWithTitle:@"View"];
    if (item) return item;
    item = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    [item setSubmenu:[[NSMenu alloc] initWithTitle:@"View"]];
    [main addItem:item];
    return item;
}

+ (void)setupMenu {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSMenu *main = [NSApp mainMenu];
        if (!main) return;
        NSMenuItem *viewItem = ensure_view_menu(main);
        [self populateMenu:[viewItem submenu]];
    });
}
@end

__attribute__((constructor))
static void init_d6_rotation(void) {
    [D6Rotator setupMenu];
}
