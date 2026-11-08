#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@implementation NSURLSession (MicroUploadFix)
+ (void)load {
    Class cls = [NSURLSession class];
    SEL sel = @selector(uploadTaskWithRequest:fromFile:);
    Method orig = class_getInstanceMethod(cls, sel);
    if (!orig) return;
    NSURLSessionUploadTask *(*origImp)(id, SEL, NSURLRequest *, NSURL *) = (void *)method_getImplementation(orig);
    id blk = ^NSURLSessionUploadTask *(id selfSession, NSURLRequest *req, NSURL *fileURL) {
        if (!req || !fileURL) return nil;
        @try { return origImp(selfSession, sel, req, fileURL); }
        @catch (NSException *e) { return nil; }
    };
    method_setImplementation(orig, imp_implementationWithBlock(blk));
}
@end
