#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static CFMutableDictionaryRef s_ubiDict = NULL;

static id hook_defaultStore(id self, SEL _cmd) { return self; }

static id hook_objectForKey(id self, SEL _cmd, NSString *key) {
    if (!key || !s_ubiDict) return nil;
    return (id)CFDictionaryGetValue(s_ubiDict, (__bridge const void *)(key));
}

static void hook_setObject(id self, SEL _cmd, id obj, NSString *key) {
    if (!key || !s_ubiDict) return;
    if (obj) CFDictionarySetValue(s_ubiDict, (__bridge const void *)(key), (__bridge const void *)(obj));
    else CFDictionaryRemoveValue(s_ubiDict, (__bridge const void *)(key));
}

static id hook_stringForKey(id self, SEL _cmd, NSString *key) { return hook_objectForKey(self, _cmd, key); }

static long long hook_longLongForKey(id self, SEL _cmd, NSString *key) {
    id val = hook_objectForKey(self, _cmd, key);
    return [val respondsToSelector:@selector(longLongValue)] ? [val longLongValue] : 0;
}

static double hook_doubleForKey(id self, SEL _cmd, NSString *key) {
    id val = hook_objectForKey(self, _cmd, key);
    return [val respondsToSelector:@selector(doubleValue)] ? [val doubleValue] : 0.0;
}

static BOOL hook_boolForKey(id self, SEL _cmd, NSString *key) {
    id val = hook_objectForKey(self, _cmd, key);
    return [val respondsToSelector:@selector(boolValue)] ? [val boolValue] : NO;
}

static id hook_dictionaryRepresentation(id self, SEL _cmd) {
    return s_ubiDict ? (__bridge id)s_ubiDict : [NSDictionary dictionary];
}

static BOOL hook_synchronize(id self, SEL _cmd) { return YES; }

static void hook_pair(Class cls, Class meta, SEL sel, IMP imp, const char *types) {
    Method mi = class_getInstanceMethod(cls, sel);
    if (mi) method_setImplementation(mi, imp);
    else class_addMethod(cls, sel, imp, types);
    Method mm = class_getInstanceMethod(meta, sel);
    if (mm) method_setImplementation(mm, imp);
    else class_addMethod(meta, sel, imp, types);
}

static void install_ubi_methods(Class ubiCls, Class meta) {
    SEL sels[] = {
        sel_registerName("objectForKey:"), sel_registerName("setObject:forKey:"),
        sel_registerName("stringForKey:"), sel_registerName("setString:forKey:"),
        sel_registerName("longLongForKey:"), sel_registerName("setLongLong:forKey:"),
        sel_registerName("doubleForKey:"), sel_registerName("setDouble:forKey:"),
        sel_registerName("boolForKey:"), sel_registerName("setBool:forKey:"),
        sel_registerName("dictionaryRepresentation"), sel_registerName("synchronize")
    };
    IMP imps[] = {
        (IMP)hook_objectForKey, (IMP)hook_setObject, (IMP)hook_stringForKey, (IMP)hook_setObject,
        (IMP)hook_longLongForKey, (IMP)hook_setObject, (IMP)hook_doubleForKey, (IMP)hook_setObject,
        (IMP)hook_boolForKey, (IMP)hook_setObject, (IMP)hook_dictionaryRepresentation, (IMP)hook_synchronize
    };
    for (size_t i = 0; i < sizeof(sels)/sizeof(sels[0]); i++) {
        hook_pair(ubiCls, meta, sels[i], imps[i], "@@:@");
    }
}

__attribute__((constructor))
static void init_ubiquitous_module(void) {
    s_ubiDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    Class ubiCls = objc_getClass("NSUbiquitousKeyValueStore");
    if (!ubiCls) return;
    Class meta = object_getClass((id)ubiCls);
    Method m = class_getInstanceMethod(meta, sel_registerName("defaultStore"));
    if (m) method_setImplementation(m, (IMP)hook_defaultStore);
    install_ubi_methods(ubiCls, meta);
}
