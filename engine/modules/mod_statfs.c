#include <CoreFoundation/CoreFoundation.h>
#include <sys/mount.h>
#include <sys/statvfs.h>
#include <objc/runtime.h>
#include <stdbool.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

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

static bool (*orig_getResourceValue)(void *, SEL, void **, CFStringRef, void **);

static bool is_capacity_key(CFStringRef key) {
    if (!key) return false;
    if (CFEqual(key, CFSTR("NSURLVolumeAvailableCapacityKey"))) return true;
    if (CFEqual(key, CFSTR("NSURLVolumeAvailableCapacityForImportantUsageKey"))) return true;
    if (CFEqual(key, CFSTR("NSURLVolumeAvailableCapacityForOpportunisticUsageKey"))) return true;
    return false;
}

static bool hook_getResourceValue(void *self, SEL _cmd, void **value, CFStringRef key, void **error) {
    if (is_capacity_key(key)) {
        long long cap = 64ULL * 1024 * 1024 * 1024;
        if (value) *value = (void *)CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &cap);
        return true;
    }
    if (orig_getResourceValue) return orig_getResourceValue(self, _cmd, value, key, error);
    return false;
}

__attribute__((constructor))
static void init_statfs_spoof(void) {
    Class cls = objc_getClass("NSURL");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName("getResourceValue:forKey:error:"));
    if (m && !orig_getResourceValue) {
        orig_getResourceValue = (bool (*)(void *, SEL, void **, CFStringRef, void **))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_getResourceValue);
    }
}
