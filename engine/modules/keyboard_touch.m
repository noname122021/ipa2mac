// keyboard_touch.m — keyboard keys as touches, for touch-only games (PlayCover-style keymapping, minimal).
//
// A mapped key held = a finger held at a fixed point of the window. While the swipe key is held, each
// mouse/trackpad stroke is a swipe (ends after swipe_idle frames of rest); without it the mouse works as before. Mapped keys
// never reach the game (no "unhandled key" beep). Touches go straight to the view under the point
// (touchesBegan/Moved/Ended:withEvent:) through a UITouch subclass reporting our location and phase.
//
// Recipe:
//   [shims]          keyboard_touch = true
//   [keyboard_touch] map = a:0.08,0.88 d:0.92,0.88 e:0.50,0.88   ; key:x,y (0..1, top-left origin)
//                    swipe_key = space
//                    joystick = w,a,s,d:0.22,0.75,0.15   ; up,left,down,right:x,y,radius (radius in window heights)
// Keys: a-z 0-9 space enter tab escape f1-f12 left_shift left_ctrl left_alt (see kKeys)

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#ifndef KEYBOARD_TOUCH_MAP
#define KEYBOARD_TOUCH_MAP ""
#endif
#ifndef KEYBOARD_TOUCH_SWIPE_IDLE   // frames of rest that end a swipe stroke
#define KEYBOARD_TOUCH_SWIPE_IDLE 4
#endif
#ifndef KEYBOARD_TOUCH_SWIPE_KEY
#define KEYBOARD_TOUCH_SWIPE_KEY "space"
#endif
#ifndef KEYBOARD_TOUCH_JOYSTICK   // empty = no joystick
#define KEYBOARD_TOUCH_JOYSTICK ""
#endif

static const struct { const char *name; long code; } kKeys[] = {
    {"space", 44}, {"enter", 40}, {"tab", 43}, {"escape", 41}, {"left_ctrl", 224}, {"left_shift", 225}, {"left_alt", 226}};
static long key_code(const char *n) {
    if (n[0] && !n[1] && n[0] >= 'a' && n[0] <= 'z') return 4 + n[0] - 'a';
    if (n[0] && !n[1] && n[0] >= '1' && n[0] <= '9') return 30 + n[0] - '1';
    if (!strcmp(n, "0")) return 39;
    if (n[0] == 'f' && n[1] >= '1' && n[1] <= '9') { int f = atoi(n + 1); if (f >= 1 && f <= 12) return 57 + f; }
    for (size_t i = 0; i < sizeof(kKeys) / sizeof(kKeys[0]); i++) if (!strcmp(n, kKeys[i].name)) return kKeys[i].code;
    return -1;
}

typedef struct { id touch, view; CGPoint pt, prev; long phase; } Finger;   // pt in window coords
enum { MAXB = 32 };
static struct { long key; CGPoint pos; Finger f; char name[12]; id lbl; } s_b[MAXB];
static int s_nb;
static id s_jlbl;
static BOOL s_overlay;
static long s_swipe_key;
static Finger s_sw;
static BOOL s_swiping;
static CGPoint s_last;
static int s_idle;   // frames without mouse movement
static Class s_touchClass;
static long s_jk[4] = {-1, -1, -1, -1};   // joystick keys: up, left, down, right
static BOOL s_jd[4];
static CGPoint s_jc;                      // center, 0..1
static float s_jr;                        // radius, window heights
static Finger s_jf;
static IMP o_send_event;

// ---- fake UITouch ----
static Finger *fin(id self) { return (Finger *)(uintptr_t)[objc_getAssociatedObject(self, "f") unsignedLongValue]; }
static id msg(id o, const char *s) { return ((id (*)(id, SEL))objc_msgSend)(o, sel_registerName(s)); }
static CGPoint conv(id self, CGPoint p, id v) {
    id win = msg(fin(self)->view, "window");
    return (!v || v == win) ? p : ((CGPoint (*)(id, SEL, CGPoint, id))objc_msgSend)(v, sel_registerName("convertPoint:fromView:"), p, win);
}
static CGPoint t_loc(id self, SEL _c, id v) { return conv(self, fin(self)->pt, v); }
static CGPoint t_prev(id self, SEL _c, id v) { return conv(self, fin(self)->prev, v); }
static long t_phase(id self, SEL _c) { return fin(self)->phase; }
static id t_view(id self, SEL _c) { return fin(self)->view; }
static id t_window(id self, SEL _c) { return msg(fin(self)->view, "window"); }
static unsigned long t_tap(id self, SEL _c) { return 1; }
static double t_time(id self, SEL _c) { return [[NSProcessInfo processInfo] systemUptime]; }

static id ui_window(void) {
    id app = msg((id)objc_getClass("UIApplication"), "sharedApplication");
    id w = msg(app, "keyWindow");
    return w ? w : [msg(app, "windows") firstObject];
}
static CGRect bounds_of(id v) { return ((CGRect (*)(id, SEL))objc_msgSend)(v, sel_registerName("bounds")); }

static void add_active_touches(id ev) {
    SEL addSel = sel_registerName("_addTouch:forDelayedDelivery:");
    if (![ev respondsToSelector:addSel]) return;
    if (s_jf.touch) ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ev, addSel, s_jf.touch, NO);
    if (s_sw.touch) ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ev, addSel, s_sw.touch, NO);
    for (int i = 0; i < s_nb; i++) {
        if (s_b[i].f.touch) ((void (*)(id, SEL, id, BOOL))objc_msgSend)(ev, addSel, s_b[i].f.touch, NO);
    }
}
static void deliver(Finger *f, const char *sel) {
    id app = msg((id)objc_getClass("UIApplication"), "sharedApplication");
    id ev = msg(app, "_touchesEvent");
    if (ev && [ev respondsToSelector:sel_registerName("_clearTouches")] &&
        [ev respondsToSelector:sel_registerName("_addTouch:forDelayedDelivery:")]) {
        ((void (*)(id, SEL))objc_msgSend)(ev, sel_registerName("_clearTouches"));
        add_active_touches(ev);
        if (o_send_event) ((void (*)(id, SEL, id))o_send_event)(app, sel_registerName("sendEvent:"), ev);
        else ((void (*)(id, SEL, id))objc_msgSend)(app, sel_registerName("sendEvent:"), ev);
        return;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(f->view, sel_registerName(sel), [NSSet setWithObject:f->touch], nil);
}
static id make_lbl(id win, const char *txt, CGPoint p) {
    id l = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("UILabel"), sel_registerName("alloc"));
    l = ((id (*)(id, SEL, CGRect))objc_msgSend)(l, sel_registerName("initWithFrame:"), CGRectMake(0, 0, 44, 22));
    ((void (*)(id, SEL, id))objc_msgSend)(l, sel_registerName("setText:"), [NSString stringWithUTF8String:txt]);
    ((void (*)(id, SEL, long))objc_msgSend)(l, sel_registerName("setTextAlignment:"), 1);
    ((void (*)(id, SEL, id))objc_msgSend)(l, sel_registerName("setTextColor:"), msg((id)objc_getClass("UIColor"), "whiteColor"));
    id bg = ((id (*)(id, SEL, double, double))objc_msgSend)((id)objc_getClass("UIColor"), sel_registerName("colorWithWhite:alpha:"), 0.0, 0.55);
    ((void (*)(id, SEL, id))objc_msgSend)(l, sel_registerName("setBackgroundColor:"), bg);
    ((void (*)(id, SEL, id))objc_msgSend)(l, sel_registerName("setFont:"), ((id (*)(id, SEL, double))objc_msgSend)((id)objc_getClass("UIFont"), sel_registerName("boldSystemFontOfSize:"), 11.0));
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(l, sel_registerName("setCenter:"), p);
    ((void (*)(id, SEL, id))objc_msgSend)(win, sel_registerName("addSubview:"), l);
    return l;
}
static void toggle_overlay(void) {
    s_overlay = !s_overlay;
    id win = ui_window();
    if (!win) return;
    CGRect b = bounds_of(win);
    for (int i = 0; i < s_nb; i++) {
        if (s_overlay && !s_b[i].lbl) s_b[i].lbl = make_lbl(win, s_b[i].name, CGPointMake(s_b[i].pos.x * b.size.width, s_b[i].pos.y * b.size.height));
        else if (!s_overlay && s_b[i].lbl) { ((void (*)(id, SEL))objc_msgSend)(s_b[i].lbl, sel_registerName("removeFromSuperview")); [s_b[i].lbl release]; s_b[i].lbl = nil; }
    }
    if (s_overlay && s_jk[0] >= 0 && !s_jlbl) s_jlbl = make_lbl(win, "WASD", CGPointMake(s_jc.x * b.size.width, s_jc.y * b.size.height));
    else if (!s_overlay && s_jlbl) { ((void (*)(id, SEL))objc_msgSend)(s_jlbl, sel_registerName("removeFromSuperview")); [s_jlbl release]; s_jlbl = nil; }
}
static void hl_lbl(id l, BOOL on) {
    if (!l) return;
    id bg = ((id (*)(id, SEL, double, double))objc_msgSend)((id)objc_getClass("UIColor"), sel_registerName("colorWithWhite:alpha:"), on ? 0.9 : 0.0, on ? 0.8 : 0.55);
    ((void (*)(id, SEL, id))objc_msgSend)(l, sel_registerName("setBackgroundColor:"), bg);
}
static void finger_down(Finger *f, CGPoint p) {
    id win = ui_window();
    if (f->touch || !win) return;
    f->view = [((id (*)(id, SEL, CGPoint, id))objc_msgSend)(win, sel_registerName("hitTest:withEvent:"), p, nil) retain];
    if (!f->view) return;
    f->touch = [objc_getClass("UITouch") new];
    ((void (*)(id, SEL, id))objc_msgSend)(f->touch, sel_registerName("setWindow:"), win);
    ((void (*)(id, SEL, id))objc_msgSend)(f->touch, sel_registerName("setView:"), f->view);
    ((void (*)(id, SEL, long))objc_msgSend)(f->touch, sel_registerName("setPhase:"), 0);
    ((void (*)(id, SEL, unsigned long))objc_msgSend)(f->touch, sel_registerName("setTapCount:"), 1);
    ((void (*)(id, SEL, double))objc_msgSend)(f->touch, sel_registerName("setTimestamp:"), [[NSProcessInfo processInfo] systemUptime]);
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(f->touch, sel_registerName("_setLocationInWindow:resetPrevious:"), p, YES);
    f->pt = f->prev = p; f->phase = 0;
    deliver(f, "touchesBegan:withEvent:");
}
static void finger_move(Finger *f, CGPoint p) {
    if (!f->touch || CGPointEqualToPoint(p, f->pt)) return;
    f->prev = f->pt; f->pt = p; f->phase = 1;
    ((void (*)(id, SEL, long))objc_msgSend)(f->touch, sel_registerName("setPhase:"), 1);
    ((void (*)(id, SEL, double))objc_msgSend)(f->touch, sel_registerName("setTimestamp:"), [[NSProcessInfo processInfo] systemUptime]);
    ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(f->touch, sel_registerName("_setLocationInWindow:resetPrevious:"), p, NO);
    deliver(f, "touchesMoved:withEvent:");
}
static void finger_up(Finger *f) {
    if (!f->touch) return;
    f->prev = f->pt; f->phase = 3;
    ((void (*)(id, SEL, long))objc_msgSend)(f->touch, sel_registerName("setPhase:"), 3);
    ((void (*)(id, SEL, double))objc_msgSend)(f->touch, sel_registerName("setTimestamp:"), [[NSProcessInfo processInfo] systemUptime]);
    deliver(f, "touchesEnded:withEvent:");
    [f->touch release]; [f->view release];
    f->touch = f->view = nil;
}

// Mouse cursor in UIWindow coordinates (scaled from the NSWindow content view).
static CGPoint mouse_pt(void) {
    NSWindow *nw = [NSApp keyWindow];
    id uw = ui_window();
    if (!nw || !uw) return CGPointZero;
    NSPoint p = [nw convertPointFromScreen:[NSEvent mouseLocation]];
    NSSize cs = nw.contentView.bounds.size;
    CGRect ub = bounds_of(uw);
    return CGPointMake(p.x / cs.width * ub.size.width, (cs.height - p.y) / cs.height * ub.size.height);
}

// Joystick: a finger goes down at the center when the first direction key is pressed, slides to
// center + direction * radius while keys change, lifts when all are released.
static void joystick_update(void) {
    CGRect b = bounds_of(ui_window());
    CGPoint c = CGPointMake(s_jc.x * b.size.width, s_jc.y * b.size.height);
    float dx = s_jd[3] - s_jd[1], dy = s_jd[2] - s_jd[0], len = hypotf(dx, dy);
    if (len == 0) { finger_up(&s_jf); return; }
    float r = s_jr * b.size.height / len;
    CGPoint target = CGPointMake(c.x + dx * r, c.y + dy * r);
    if (!s_jf.touch) {
        finger_down(&s_jf, c);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s_jf.touch) finger_move(&s_jf, target);
        });
    } else {
        finger_move(&s_jf, target);
    }
}

static BOOL key_event(long code, BOOL down) {
    if ((code == 53 || code == 69) && down) { toggle_overlay(); return YES; }   // ` (grave) or F12
    for (int i = 0; i < 4; i++) if (s_jk[i] == code) {
        if (s_jd[i] != down) { s_jd[i] = down; joystick_update(); hl_lbl(s_jlbl, s_jd[0]||s_jd[1]||s_jd[2]||s_jd[3]); }
        return YES;
    }
    if (code == s_swipe_key) {
        s_swiping = down;
        if (!down) finger_up(&s_sw);
        s_last = mouse_pt(); s_idle = 0;
        return YES;
    }
    for (int i = 0; i < s_nb; i++) if (s_b[i].key == code) {
        hl_lbl(s_b[i].lbl, down);
        if (down) {
            CGRect b = bounds_of(ui_window());
            finger_down(&s_b[i].f, CGPointMake(s_b[i].pos.x * b.size.width, s_b[i].pos.y * b.size.height));
        } else finger_up(&s_b[i].f);
        return YES;
    }
    return NO;
}

static void h_send_event(id self, SEL _cmd, id event) {
    NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
    if (type == 4 && [event respondsToSelector:sel_registerName("_keyCode")]) {   // UIPhysicalKeyboardEvent
        long code = ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("_keyCode"));
        BOOL down = ((BOOL (*)(id, SEL))objc_msgSend)(event, sel_registerName("_isKeyDown"));
        if (key_event(code, down)) return;
    }
    if (type == 0) add_active_touches(event);
    ((void (*)(id, SEL, id))o_send_event)(self, _cmd, event);
}

@interface IPA2MacKeyTouchTick : NSObject
@end
@implementation IPA2MacKeyTouchTick
// While the swipe key is held, each mouse/trackpad stroke is one swipe: finger down when the cursor starts
// moving, up after it rests for a few frames.
- (void)tick:(id)link {
    if (!s_swiping) return;
    CGPoint p = mouse_pt();
    BOOL moved = hypot(p.x - s_last.x, p.y - s_last.y) > 0.5;
    if (moved && !s_sw.touch) finger_down(&s_sw, s_last);
    if (moved) { finger_move(&s_sw, p); s_idle = 0; }
    else if (s_sw.touch && ++s_idle >= KEYBOARD_TOUCH_SWIPE_IDLE) finger_up(&s_sw);
    s_last = p;
}
@end

__attribute__((constructor))
static void init_keyboard_touch(void) {
    @autoreleasepool {
        char buf[1024]; strlcpy(buf, KEYBOARD_TOUCH_MAP, sizeof buf);
        for (char *tok = strtok(buf, " "); tok && s_nb < MAXB; tok = strtok(NULL, " ")) {
            char *c = strchr(tok, ':'); float x, y;
            if (!c) continue;
            *c = 0;
            long k = key_code(tok);
            if (k < 0 || sscanf(c + 1, "%f,%f", &x, &y) != 2) { NSLog(@"[ipa2mac] keyboard_touch: bad entry %s", tok); continue; }
            s_b[s_nb].key = k; s_b[s_nb].pos = CGPointMake(x, y); strlcpy(s_b[s_nb].name, tok, sizeof(s_b[s_nb].name)); s_nb++;
        }
        s_swipe_key = key_code(KEYBOARD_TOUCH_SWIPE_KEY);
        if (KEYBOARD_TOUCH_JOYSTICK[0]) {
            char u[16], l[16], d[16], rt[16]; float x, y, rad;
            if (sscanf(KEYBOARD_TOUCH_JOYSTICK, "%15[^,],%15[^,],%15[^,],%15[^:]:%f,%f,%f", u, l, d, rt, &x, &y, &rad) == 7) {
                s_jk[0] = key_code(u); s_jk[1] = key_code(l); s_jk[2] = key_code(d); s_jk[3] = key_code(rt);
                s_jc = CGPointMake(x, y); s_jr = rad;
            } else NSLog(@"[ipa2mac] keyboard_touch: bad joystick %s", KEYBOARD_TOUCH_JOYSTICK);
        }

        Class ut = objc_getClass("UITouch"), app = objc_getClass("UIApplication");
        if (!ut || !app) return;
        s_touchClass = objc_allocateClassPair(ut, "IPA2MacKeyTouch", 0);
        class_addMethod(s_touchClass, sel_registerName("locationInView:"), (IMP)t_loc, "{CGPoint=dd}24@0:8@16");
        class_addMethod(s_touchClass, sel_registerName("previousLocationInView:"), (IMP)t_prev, "{CGPoint=dd}24@0:8@16");
        class_addMethod(s_touchClass, sel_registerName("phase"), (IMP)t_phase, "q16@0:8");
        class_addMethod(s_touchClass, sel_registerName("view"), (IMP)t_view, "@16@0:8");
        class_addMethod(s_touchClass, sel_registerName("window"), (IMP)t_window, "@16@0:8");
        class_addMethod(s_touchClass, sel_registerName("tapCount"), (IMP)t_tap, "Q16@0:8");
        class_addMethod(s_touchClass, sel_registerName("timestamp"), (IMP)t_time, "d16@0:8");
        objc_registerClassPair(s_touchClass);

        Method m = class_getInstanceMethod(app, sel_registerName("sendEvent:"));
        if (m) o_send_event = method_setImplementation(m, (IMP)h_send_event);

        [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            id link = ((id (*)(id, SEL, id, SEL))objc_msgSend)(objc_getClass("CADisplayLink"),
                sel_registerName("displayLinkWithTarget:selector:"), [IPA2MacKeyTouchTick new], @selector(tick:));
            ((void (*)(id, SEL, id, id))objc_msgSend)(link, sel_registerName("addToRunLoop:forMode:"), [NSRunLoop mainRunLoop], NSRunLoopCommonModes);
        }];
        NSLog(@"[ipa2mac] keyboard_touch: %d keys, swipe key %s", s_nb, KEYBOARD_TOUCH_SWIPE_KEY);
    }
}
