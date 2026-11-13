// virtual_gamepad.m — keyboard + mouse/trackpad as a virtual MFi extended gamepad.
//
// For games that support game controllers but not a Mac keyboard/mouse. A software controller
// (+[GCController controllerWithExtendedGamepad]) is added to +[GCController controllers] and fed from
// GCKeyboard / GCMouse. The real keyboard and mouse are hidden from the game, so it cannot grab the
// pointer for its own (often broken on Catalyst) mouse handling.
//
// A click in the game window captures the mouse; the capture key toggles it: cursor hidden and locked, mouse moves drive the right stick,
// mouse buttons are mappable and the game gets no touches. When the app loses focus, the mouse is released.
//
// Recipe:
//   [shims]           virtual_gamepad = true
//   [virtual_gamepad] map = w:ls_up s:ls_down a:ls_left d:ls_right mouse_left:rt mouse_right:lt space:a ...
//                     mouse_sensitivity = 0.05     ; stick deflection per point of mouse movement per frame
//                     capture_key = left_alt
//                     block_touches = true         ; game never gets touches/trackpad gestures (no touch-mode switch)
// Keys: a-z 0-9 f1-f12 space enter esc tab backspace capslock minus equal grave comma period slash
//       semicolon quote up down left right left_shift right_shift left_ctrl right_ctrl left_alt
//       right_alt left_cmd right_cmd mouse_left mouse_right mouse_middle
// Targets: a b x y lb rb lt rt l3 r3 menu options dpad_* ls_* rs_* (* = up/down/left/right)

#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>

#ifndef VIRTUAL_GAMEPAD_MAP
#define VIRTUAL_GAMEPAD_MAP "w:ls_up s:ls_down a:ls_left d:ls_right up:dpad_up down:dpad_down left:dpad_left " \
    "right:dpad_right space:a q:b e:x f:y mouse_left:rt mouse_right:lt esc:menu tab:options"
#endif
#ifndef VIRTUAL_GAMEPAD_MOUSE_SENSITIVITY
#define VIRTUAL_GAMEPAD_MOUSE_SENSITIVITY "0.05"
#endif
#ifndef VIRTUAL_GAMEPAD_BLOCK_TOUCHES
#define VIRTUAL_GAMEPAD_BLOCK_TOUCHES 1
#endif
#ifndef VIRTUAL_GAMEPAD_MOUSE_CAPTURE   // 0: clicks go to the game as taps, no pointer capture
#define VIRTUAL_GAMEPAD_MOUSE_CAPTURE 1
#endif
#ifndef VIRTUAL_GAMEPAD_ANNOUNCE        // 1: always post GCControllerDidConnect (games that only add on connect)
#define VIRTUAL_GAMEPAD_ANNOUNCE 0
#endif
#ifndef VIRTUAL_GAMEPAD_CAPTURE_KEY
#define VIRTUAL_GAMEPAD_CAPTURE_KEY "left_alt"
#endif

enum { T_A, T_B, T_X, T_Y, T_LB, T_RB, T_LT, T_RT, T_L3, T_R3, T_MENU, T_OPTIONS, T_NBUTTONS,
       T_DPAD = T_NBUTTONS, T_LS = T_DPAD + 4, T_RS = T_LS + 4, T_COUNT = T_RS + 4 };   // pads: up,down,left,right
static const char *kTargets[T_COUNT] = {
    "a", "b", "x", "y", "lb", "rb", "lt", "rt", "l3", "r3", "menu", "options",
    "dpad_up", "dpad_down", "dpad_left", "dpad_right", "ls_up", "ls_down", "ls_left", "ls_right",
    "rs_up", "rs_down", "rs_left", "rs_right"};

// Key name -> HID usage (= GCKeyCode); mouse buttons use pseudo codes.
enum { K_MOUSE_LEFT = 0x1001, K_MOUSE_RIGHT, K_MOUSE_MIDDLE };
static const struct { const char *name; long code; } kKeys[] = {
    {"space", 44}, {"enter", 40}, {"esc", 41}, {"backspace", 42}, {"tab", 43}, {"capslock", 57},
    {"minus", 45}, {"equal", 46}, {"grave", 53}, {"comma", 54}, {"period", 55}, {"slash", 56},
    {"semicolon", 51}, {"quote", 52}, {"right", 79}, {"left", 80}, {"down", 81}, {"up", 82},
    {"left_ctrl", 224}, {"left_shift", 225}, {"left_alt", 226}, {"left_cmd", 227},
    {"right_ctrl", 228}, {"right_shift", 229}, {"right_alt", 230}, {"right_cmd", 231},
    {"mouse_left", K_MOUSE_LEFT}, {"mouse_right", K_MOUSE_RIGHT}, {"mouse_middle", K_MOUSE_MIDDLE}};

static long key_code(const char *n) {
    if (n[0] && !n[1] && n[0] >= 'a' && n[0] <= 'z') return 4 + n[0] - 'a';
    if (n[0] && !n[1] && n[0] >= '1' && n[0] <= '9') return 30 + n[0] - '1';
    if (!strcmp(n, "0")) return 39;
    if (n[0] == 'f' && atoi(n + 1) >= 1 && atoi(n + 1) <= 12) return 57 + atoi(n + 1);
    for (size_t i = 0; i < sizeof(kKeys) / sizeof(kKeys[0]); i++)
        if (!strcmp(n, kKeys[i].name)) return kKeys[i].code;
    return -1;
}

static struct { long key; int target; } s_bind[128];
static int s_nbind, s_held[T_COUNT];   // per target: number of its keys currently down
static BOOL s_down[K_MOUSE_MIDDLE + 1];   // per key: down (ignores key-repeat downs)
static long s_capture_key;
static float s_sens, s_mdx, s_mdy;
static float s_last[T_COUNT];            // last value sent per button / pad axis slot
static BOOL s_captured, s_seen_by_game;
static GCController *s_ctrl;
static IMP o_controllers, o_mouse_current, o_mice, o_add_block, o_add_sel, o_send_event;

static void parse_map(void) {
    char buf[2048];
    strlcpy(buf, VIRTUAL_GAMEPAD_MAP, sizeof(buf));
    for (char *tok = strtok(buf, " \t"); tok && s_nbind < 128; tok = strtok(NULL, " \t")) {
        char *colon = strchr(tok, ':');
        if (!colon) continue;
        *colon = 0;
        long k = key_code(tok);
        int t = -1;
        for (int i = 0; i < T_COUNT; i++) if (!strcmp(colon + 1, kTargets[i])) t = i;
        if (k < 0 || t < 0) { NSLog(@"[ipa2mac] virtual_gamepad: bad mapping %s:%s", tok, colon + 1); continue; }
        s_bind[s_nbind].key = k;
        s_bind[s_nbind++].target = t;
    }
    s_capture_key = key_code(VIRTUAL_GAMEPAD_CAPTURE_KEY);
    s_sens = atof(VIRTUAL_GAMEPAD_MOUSE_SENSITIVITY);
}

// ---- output: push state into the virtual controller (only changed values) ----
static float clampf(float v) { return v < -1 ? -1 : v > 1 ? 1 : v; }

static void set_button(GCControllerButtonInput *b, int slot, float v) {
    if (s_last[slot] != v) { s_last[slot] = v; [b setValue:v]; }
}

static void set_pad(GCControllerDirectionPad *p, int base, float x, float y) {
    if (s_last[base] != x || s_last[base + 1] != y) {
        s_last[base] = x; s_last[base + 1] = y;
        [p setValueForXAxis:x yAxis:y];
    }
}

static float axis(int base, int neg, int pos) { return (s_held[base + pos] ? 1 : 0) - (s_held[base + neg] ? 1 : 0); }

static void apply(void) {
    GCExtendedGamepad *g = s_ctrl.extendedGamepad;
    if (!g) return;
    GCControllerButtonInput *btn[T_NBUTTONS] = {
        g.buttonA, g.buttonB, g.buttonX, g.buttonY, g.leftShoulder, g.rightShoulder, g.leftTrigger,
        g.rightTrigger, g.leftThumbstickButton, g.rightThumbstickButton, g.buttonMenu, g.buttonOptions};
    for (int i = 0; i < T_NBUTTONS; i++) if (btn[i]) set_button(btn[i], i, s_held[i] ? 1 : 0);
    set_pad(g.dpad, T_DPAD, axis(T_DPAD, 2, 3), axis(T_DPAD, 1, 0));
    set_pad(g.leftThumbstick, T_LS, axis(T_LS, 2, 3), axis(T_LS, 1, 0));
    set_pad(g.rightThumbstick, T_RS, clampf(axis(T_RS, 2, 3) + s_mdx * s_sens),
            clampf(axis(T_RS, 1, 0) + s_mdy * s_sens));
    s_mdx = s_mdy = 0;
}

// Once per display frame: mouse movement is accumulated between frames and turned into stick deflection.
@interface IPA2MacGamepadTick : NSObject
@end
@implementation IPA2MacGamepadTick
- (void)tick:(id)link { apply(); }
@end

// ---- mouse capture ----
static void set_captured(BOOL on) {
    if (s_captured == on) return;
    s_captured = on;
    if (on) {
        NSWindow *w = [NSApp keyWindow];
        if (w) {   // park the cursor in the middle of the window (CG coordinates are top-left based)
            NSRect f = w.frame;
            CGFloat top = NSMaxY([NSScreen screens].firstObject.frame);
            CGWarpMouseCursorPosition(CGPointMake(NSMidX(f), top - NSMidY(f)));
        }
        CGAssociateMouseAndMouseCursorPosition(false);
        [NSCursor hide];
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
    }
}

// ---- input ----
static BOOL is_bound(long code) {
    if (code == s_capture_key) return YES;
    for (int i = 0; i < s_nbind; i++) if (s_bind[i].key == code) return YES;
    return NO;
}

static void on_key(long code, BOOL pressed) {
    if (code < 0 || code > K_MOUSE_MIDDLE || s_down[code] == pressed) return;
    s_down[code] = pressed;
    if (code == s_capture_key) { if (pressed) set_captured(!s_captured); return; }
    if (VIRTUAL_GAMEPAD_MOUSE_CAPTURE && code >= K_MOUSE_LEFT && pressed && !s_captured) {   // a click inside the game window captures the mouse
        NSWindow *w = [NSApp keyWindow];
        NSRect content = [w convertRectToScreen:w.contentLayoutRect];
        if (w && NSPointInRect([NSEvent mouseLocation], content)) set_captured(YES);
        return;
    }
    for (int i = 0; i < s_nbind; i++) {
        if (s_bind[i].key != code) continue;
        int *h = &s_held[s_bind[i].target];
        *h = pressed ? *h + 1 : (*h > 0 ? *h - 1 : 0);
        if (s_bind[i].target == T_MENU && pressed && *h == 1) {   // older games only listen to controllerPausedHandler
            void (^paused)(GCController *) = ((id (*)(id, SEL))objc_msgSend)(s_ctrl, sel_registerName("controllerPausedHandler"));
            if (paused) paused(s_ctrl);
        }
    }
    apply();
}

// Key-ups that happen while the app is in the background never arrive: release everything.
static void release_all(void) {
    memset(s_down, 0, sizeof(s_down));
    memset(s_held, 0, sizeof(s_held));
    set_captured(NO);
    apply();
}

static void attach_mouse(GCMouse *m) {
    GCMouseInput *in = m.mouseInput;
    in.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
        if (s_captured) { s_mdx += dx; s_mdy += dy; }
    };
    in.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { on_key(K_MOUSE_LEFT, p); };
    in.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { on_key(K_MOUSE_RIGHT, p); };
    in.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { on_key(K_MOUSE_MIDDLE, p); };
}

static BOOL key_event(long code, BOOL down) {
    if (!is_bound(code)) return NO;
    on_key(code, down);
    return YES;
}

// ---- what the game sees ----
static NSArray *h_controllers(id cls, SEL _cmd) {
    NSArray *real = ((NSArray *(*)(id, SEL))o_controllers)(cls, _cmd);
    if (!s_ctrl) return real;
    s_seen_by_game = YES;
    return [real containsObject:s_ctrl] ? real : [real arrayByAddingObject:s_ctrl];
}
static id h_nil(id cls, SEL _cmd) { return nil; }
static NSArray *h_empty(id cls, SEL _cmd) { return @[]; }

static BOOL hidden_name(NSString *n) {
    return [n isEqualToString:GCKeyboardDidConnectNotification] || [n isEqualToString:GCMouseDidConnectNotification] ||
           [n isEqualToString:GCMouseDidBecomeCurrentNotification];
}
static id h_add_block(id self, SEL _cmd, NSString *name, id obj, NSOperationQueue *q, id block) {
    if (hidden_name(name)) return [[NSObject new] autorelease];   // the game never hears about keyboard/mouse
    return ((id (*)(id, SEL, NSString *, id, NSOperationQueue *, id))o_add_block)(self, _cmd, name, obj, q, block);
}
static void h_add_sel(id self, SEL _cmd, id observer, SEL sel, NSString *name, id obj) {
    if (hidden_name(name)) return;
    ((void (*)(id, SEL, id, SEL, NSString *, id))o_add_sel)(self, _cmd, observer, sel, name, obj);
}

// While captured, clicks must not reach the game as taps at the (frozen) cursor position.
static void h_send_event(id self, SEL _cmd, id event) {
    NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
    if (type == 4 && [event respondsToSelector:sel_registerName("_keyCode")]) {   // UIPhysicalKeyboardEvent
        long code = ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("_keyCode"));
        BOOL down = ((BOOL (*)(id, SEL))objc_msgSend)(event, sel_registerName("_isKeyDown"));
        if (key_event(code, down)) return;   // mapped: keep it from the game (and the "unhandled key" beep)
    }
    // Touches (0), scroll (10), hover (11) and trackpad gestures (14) would switch the game to touch mode.
    BOOL pointer = type == 0 || type == 10 || type == 11 || type == 14;
    if (pointer && (VIRTUAL_GAMEPAD_BLOCK_TOUCHES || s_captured)) return;
    ((void (*)(id, SEL, id))o_send_event)(self, _cmd, event);
}

static IMP swap_class(Class c, SEL s, IMP imp) {
    Method m = class_getClassMethod(c, s);
    return m ? method_setImplementation(m, imp) : NULL;
}

__attribute__((constructor))
static void init_virtual_gamepad(void) {
    @autoreleasepool {
        parse_map();
        s_ctrl = [[GCController controllerWithExtendedGamepad] retain];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mq = [NSOperationQueue mainQueue];

        // Our own observers first, before the hook below starts filtering these names.
        [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:mq usingBlock:^(NSNotification *n) { attach_mouse(n.object); }];
        [nc addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:mq usingBlock:^(NSNotification *n) { release_all(); }];
        [nc addObserverForName:@"UIApplicationDidFinishLaunchingNotification" object:nil queue:mq usingBlock:^(NSNotification *n) {
            // Announce the controller only if the game has not already picked it up from +controllers.
            if (VIRTUAL_GAMEPAD_ANNOUNCE || !s_seen_by_game) [nc postNotificationName:GCControllerDidConnectNotification object:s_ctrl];
            id link = ((id (*)(id, SEL, id, SEL))objc_msgSend)(objc_getClass("CADisplayLink"),
                sel_registerName("displayLinkWithTarget:selector:"), [IPA2MacGamepadTick new], @selector(tick:));
            ((void (*)(id, SEL, id, id))objc_msgSend)(link, sel_registerName("addToRunLoop:forMode:"), [NSRunLoop mainRunLoop], NSRunLoopCommonModes);
        }];

        swap_class([GCKeyboard class], @selector(coalescedKeyboard), (IMP)h_nil);
        o_mouse_current = swap_class([GCMouse class], @selector(current), (IMP)h_nil);
        o_mice = swap_class([GCMouse class], @selector(mice), (IMP)h_empty);
        for (GCMouse *m in ((NSArray *(*)(id, SEL))o_mice)([GCMouse class], @selector(mice))) attach_mouse(m);

        o_controllers = swap_class([GCController class], @selector(controllers), (IMP)h_controllers);
        Method m = class_getInstanceMethod([NSNotificationCenter class], @selector(addObserverForName:object:queue:usingBlock:));
        o_add_block = method_setImplementation(m, (IMP)h_add_block);
        m = class_getInstanceMethod([NSNotificationCenter class], @selector(addObserver:selector:name:object:));
        o_add_sel = method_setImplementation(m, (IMP)h_add_sel);
        Class app = objc_getClass("UIApplication");
        m = app ? class_getInstanceMethod(app, sel_registerName("sendEvent:")) : NULL;
        if (m) o_send_event = method_setImplementation(m, (IMP)h_send_event);
        NSLog(@"[ipa2mac] virtual_gamepad: %d bindings, capture key %s", s_nbind, VIRTUAL_GAMEPAD_CAPTURE_KEY);
    }
}
