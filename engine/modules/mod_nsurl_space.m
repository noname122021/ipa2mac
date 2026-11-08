#import <Foundation/Foundation.h>
#import <objc/runtime.h>

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
static void init_nsurl_space(void) {
    Method m = class_getInstanceMethod([NSURL class], @selector(getResourceValue:forKey:error:));
    if (m && !orig_getResourceValue) {
        orig_getResourceValue = (BOOL (*)(id, SEL, id *, NSString *, NSError **))method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_getResourceValue);
    }
}
