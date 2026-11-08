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
