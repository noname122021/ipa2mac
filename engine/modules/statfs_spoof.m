#import <Foundation/Foundation.h>
#import <sys/mount.h>
#import <sys/statvfs.h>
#import <objc/runtime.h>

#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };
#endif

static int shim_statfs(const char *path, struct statfs *buf) {
    int res = statfs(path, buf);
    if (res == 0 && buf) {
        buf->f_bavail = (64ULL * 1024 * 1024 * 1024) / (buf->f_bsize ? buf->f_bsize : 4096);
        buf->f_bfree = buf->f_bavail;
    }
    return res;
}
DYLD_INTERPOSE(shim_statfs, statfs);

static int shim_statvfs(const char *path, struct statvfs *buf) {
    int res = statvfs(path, buf);
    if (res == 0 && buf) {
        buf->f_bavail = (64ULL * 1024 * 1024 * 1024) / (buf->f_bsize ? buf->f_bsize : 4096);
        buf->f_bfree = buf->f_bavail;
    }
    return res;
}
DYLD_INTERPOSE(shim_statvfs, statvfs);

static BOOL (*orig_getResourceValue)(id, SEL, id *, NSString *, NSError **);

static BOOL hook_getResourceValue(id self, SEL _cmd, id *value, NSString *key, NSError **error) {
    if ([key isEqualToString:NSURLVolumeAvailableCapacityForImportantUsageKey] ||
        [key isEqualToString:NSURLVolumeAvailableCapacityKey] ||
        [key isEqualToString:NSURLVolumeAvailableCapacityForOpportunisticUsageKey]) {
        if (value) *value = @(64ULL * 1024 * 1024 * 1024);
        return YES;
    }
    if (orig_getResourceValue) return orig_getResourceValue(self, _cmd, value, key, error);
    return NO;
}

__attribute__((constructor))
static void init_statfs_spoof(void) {
    Method m = class_getInstanceMethod([NSURL class], @selector(getResourceValue:forKey:error:));
    if (m && !orig_getResourceValue) {
        orig_getResourceValue = (BOOL (*)(id, SEL, id *, NSString *, NSError **))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_getResourceValue);
    }
}
