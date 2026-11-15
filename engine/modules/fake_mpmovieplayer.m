#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface FakeMPMoviePlayer : NSObject
@property (nonatomic, retain) NSURL *contentURL;
@end

@implementation FakeMPMoviePlayer
- (id)initWithContentURL:(NSURL *)url {
    if ((self = [super init])) self.contentURL = url;
    return self;
}
- (id)view {
    Class uiViewCls = objc_getClass("UIView");
    return uiViewCls ? [[uiViewCls alloc] init] : [[NSObject alloc] init];
}
- (void)prepareToPlay {}
- (void)play {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *info = @{@"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey": @(0)};
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MPMoviePlayerPlaybackDidFinishNotification" object:self userInfo:info];
    });
}
- (void)stop {}
- (NSInteger)playbackState { return 1; }
- (NSInteger)loadState { return 1; }
- (void)setControlStyle:(NSInteger)s {}
- (void)setScalingMode:(NSInteger)s {}
- (void)setShouldAutoplay:(BOOL)a {}
- (void)setFullscreen:(BOOL)f animated:(BOOL)a {}
@end

__attribute__((constructor))
static void init_fake_mpmovieplayer(void) {
    if (!objc_getClass("MPMoviePlayerController")) {
        Class fakeCls = objc_allocateClassPair([FakeMPMoviePlayer class], "MPMoviePlayerController", 0);
        if (fakeCls) objc_registerClassPair(fakeCls);
    }
}
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void (*orig_idle)(id, SEL, BOOL) = NULL;
static void (*orig_idle_reason)(id, SEL, BOOL, id) = NULL;

static void hook_idle(id self, SEL _cmd, BOOL d) {
    if ([NSThread isMainThread]) {
        if (orig_idle) orig_idle(self, _cmd, d);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (orig_idle) orig_idle(self, _cmd, d);
    });
}

static void hook_idle_reason(id self, SEL _cmd, BOOL d, id r) {
    if ([NSThread isMainThread]) {
        if (orig_idle_reason) orig_idle_reason(self, _cmd, d, r);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (orig_idle_reason) orig_idle_reason(self, _cmd, d, r);
    });
}

__attribute__((constructor))
static void init_idle_timer(void) {
    Class c = objc_getClass("UIApplication");
    if (!c) return;
    Method m1 = class_getInstanceMethod(c, sel_registerName("setIdleTimerDisabled:"));
    if (m1) {
        orig_idle = (void (*)(id, SEL, BOOL))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hook_idle);
    }
    Method m2 = class_getInstanceMethod(c, sel_registerName("_setIdleTimerDisabled:forReason:"));
    if (m2) {
        orig_idle_reason = (void (*)(id, SEL, BOOL, id))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hook_idle_reason);
    }
}
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void hook_neutralize_delegate(id self, SEL _cmd, id d) {}

__attribute__((constructor))
static void init_av_delegate(void) {
    Class avCls = objc_getClass("AVAudioSession");
    if (!avCls) return;
    Method m = class_getInstanceMethod(avCls, sel_registerName("setDelegate:"));
    if (m) method_setImplementation(m, (IMP)hook_neutralize_delegate);
}
