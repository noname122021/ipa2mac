#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdbool.h>

#ifndef ASCII_PATH_TARGET
#define ASCII_PATH_TARGET "/tmp/SwordGame.app"
#endif

static NSString *s_asciiPath = nil;
static NSString *(*orig_bundlePath)(id, SEL) = NULL;
static NSString *(*orig_resourcePath)(id, SEL) = NULL;

static NSString *hook_bundlePath(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle] && s_asciiPath) return s_asciiPath;
    return orig_bundlePath ? orig_bundlePath(self, _cmd) : @"";
}

static NSString *hook_resourcePath(id self, SEL _cmd) {
    if (self == [NSBundle mainBundle] && s_asciiPath) return s_asciiPath;
    return orig_resourcePath ? orig_resourcePath(self, _cmd) : @"";
}

static bool is_valid_symlink(const char *target, const char *real) {
    char link_buf[PATH_MAX];
    ssize_t len = readlink(target, link_buf, sizeof(link_buf) - 1);
    if (len <= 0) return false;
    link_buf[len] = '\0';
    return (strcmp(link_buf, real) == 0);
}

static void ensure_ascii_symlink(const char *target) {
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t sz = sizeof(exe);
    if (_NSGetExecutablePath(exe, &sz) != 0) return;
    strncpy(real, exe, sizeof(real) - 1);
    real[sizeof(real) - 1] = '\0';
    char *slash = strrchr(real, '/');
    if (slash) *slash = '\0';

    struct stat st;
    if (lstat(target, &st) == 0 && S_ISLNK(st.st_mode)) {
        if (is_valid_symlink(target, real)) return;
        unlink(target);
    }
    symlink(real, target);
}

__attribute__((constructor))
static void init_ascii_path_redirect(void) {
    ensure_ascii_symlink(ASCII_PATH_TARGET);
    s_asciiPath = [NSString stringWithUTF8String:ASCII_PATH_TARGET];
    Class bCls = [NSBundle class];
    Method mBP = class_getInstanceMethod(bCls, @selector(bundlePath));
    if (mBP && !orig_bundlePath) {
        orig_bundlePath = (NSString *(*)(id, SEL))method_getImplementation(mBP);
        method_setImplementation(mBP, (IMP)hook_bundlePath);
    }
    Method mRP = class_getInstanceMethod(bCls, @selector(resourcePath));
    if (mRP && !orig_resourcePath) {
        orig_resourcePath = (NSString *(*)(id, SEL))method_getImplementation(mRP);
        method_setImplementation(mRP, (IMP)hook_resourcePath);
    }
}
