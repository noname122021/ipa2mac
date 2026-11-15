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
static struct { long key; CGPoint pos; Finger f; } s_b[MAXB];
static int s_nb;
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

static void deliver(Finger *f, const char *sel) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(f->view, sel_registerName(sel), [NSSet setWithObject:f->touch], nil);
}
static void finger_down(Finger *f, CGPoint p) {
    id win = ui_window();
    if (f->touch || !win) return;
    f->view = [((id (*)(id, SEL, CGPoint, id))objc_msgSend)(win, sel_registerName("hitTest:withEvent:"), p, nil) retain];
    if (!f->view) return;
    f->touch = [s_touchClass new];
    objc_setAssociatedObject(f->touch, "f", @((uintptr_t)f), OBJC_ASSOCIATION_RETAIN);
    f->pt = f->prev = p; f->phase = 0;
    deliver(f, "touchesBegan:withEvent:");
}
static void finger_move(Finger *f, CGPoint p) {
    if (!f->touch || CGPointEqualToPoint(p, f->pt)) return;
    f->prev = f->pt; f->pt = p; f->phase = 1;
    deliver(f, "touchesMoved:withEvent:");
}
static void finger_up(Finger *f) {
    if (!f->touch) return;
    f->prev = f->pt; f->phase = 3;
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
    if (!s_jf.touch) finger_down(&s_jf, c);
    finger_move(&s_jf, CGPointMake(c.x + dx * r, c.y + dy * r));
}

static BOOL key_event(long code, BOOL down) {
    for (int i = 0; i < 4; i++) if (s_jk[i] == code) {
        if (s_jd[i] != down) { s_jd[i] = down; joystick_update(); }
        return YES;
    }
    if (code == s_swipe_key) {
        s_swiping = down;
        if (!down) finger_up(&s_sw);
        s_last = mouse_pt(); s_idle = 0;
        return YES;
    }
    for (int i = 0; i < s_nb; i++) if (s_b[i].key == code) {
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
            s_b[s_nb].key = k; s_b[s_nb].pos = CGPointMake(x, y); s_nb++;
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
