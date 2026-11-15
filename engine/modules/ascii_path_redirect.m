// Some engines (e.g. UE3) can't open files when the bundle path has non-ASCII
// characters. At launch, link /tmp/<executable>.app -> the real bundle and make
// NSBundle.mainBundle report that path. Recreated on every launch, so a /tmp
// wipe or a moved app is harmless.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *s_path;
static IMP orig_bundlePath, orig_resourcePath;

static NSString *hook_bundlePath(id self, SEL cmd) {
    return self == [NSBundle mainBundle] ? s_path : ((NSString *(*)(id, SEL))orig_bundlePath)(self, cmd);
}
static NSString *hook_resourcePath(id self, SEL cmd) {
    return self == [NSBundle mainBundle] ? s_path : ((NSString *(*)(id, SEL))orig_resourcePath)(self, cmd);
}

__attribute__((constructor))
static void init_ascii_path_redirect(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSString *real = [b bundlePath], *exe = [[b executablePath] lastPathComponent];
    NSString *link = [NSString stringWithFormat:@"/tmp/%@.app", exe];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![[fm destinationOfSymbolicLinkAtPath:link error:nil] isEqual:real]) {
        [fm removeItemAtPath:link error:nil];
        if (![fm createSymbolicLinkAtPath:link withDestinationPath:real error:nil]) return;
    }
    s_path = link;
    orig_bundlePath = method_setImplementation(class_getInstanceMethod([NSBundle class], @selector(bundlePath)), (IMP)hook_bundlePath);
    orig_resourcePath = method_setImplementation(class_getInstanceMethod([NSBundle class], @selector(resourcePath)), (IMP)hook_resourcePath);
}
