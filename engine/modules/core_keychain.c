#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <pthread.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static CFMutableDictionaryRef s_keychain_dict = NULL;
static pthread_mutex_t s_keychain_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

static const void *get_key(CFDictionaryRef dict) {
    if (!dict) return CFSTR("default");
    const void *val = CFDictionaryGetValue(dict, kSecAttrAccount);
    if (!val) val = CFDictionaryGetValue(dict, kSecAttrService);
    return val ? val : CFSTR("default");
}

static const void *get_val(CFDictionaryRef dict) {
    if (!dict) return CFSTR("");
    const void *val = CFDictionaryGetValue(dict, kSecValueData);
    if (!val) val = CFDictionaryGetValue(dict, kSecValueRef);
    return val ? val : CFSTR("");
}

static CFTypeRef format_keychain_item(CFDictionaryRef query, const void *k, const void *v) {
    const void *retAttrs = query ? CFDictionaryGetValue(query, kSecReturnAttributes) : NULL;
    Boolean isAttrs = (retAttrs && CFEqual(retAttrs, kCFBooleanTrue));
    if (!isAttrs) return CFRetain(v);

    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, kSecAttrAccount, k);
    CFDictionarySetValue(dict, kSecValueData, v);
    return dict;
}

static OSStatus shim_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    pthread_mutex_lock(&s_keychain_lock);
    if (!s_keychain_dict) {
        s_keychain_dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    const void *k = get_key(attributes);
    const void *v = get_val(attributes);
    CFDictionarySetValue(s_keychain_dict, k, v);
    if (result) *result = CFRetain(v);
    pthread_mutex_unlock(&s_keychain_lock);
    return errSecSuccess;
}

static OSStatus shim_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    pthread_mutex_lock(&s_keychain_lock);
    if (!s_keychain_dict) {
        pthread_mutex_unlock(&s_keychain_lock);
        return errSecItemNotFound;
    }
    const void *k = get_key(query);
    const void *v = CFDictionaryGetValue(s_keychain_dict, k);
    if (!v) {
        pthread_mutex_unlock(&s_keychain_lock);
        return errSecItemNotFound;
    }
    CFTypeRef item = format_keychain_item(query, k, v);
    const void *limit = query ? CFDictionaryGetValue(query, kSecMatchLimit) : NULL;
    if (limit && CFEqual(limit, kSecMatchLimitAll)) {
        CFArrayRef arr = CFArrayCreate(kCFAllocatorDefault, &item, 1, &kCFTypeArrayCallBacks);
        CFRelease(item);
        item = arr;
    }
    if (result) *result = item;
    pthread_mutex_unlock(&s_keychain_lock);
    return errSecSuccess;
}

static OSStatus shim_SecItemDelete(CFDictionaryRef query) {
    pthread_mutex_lock(&s_keychain_lock);
    if (s_keychain_dict) {
        const void *k = get_key(query);
        CFDictionaryRemoveValue(s_keychain_dict, k);
    }
    pthread_mutex_unlock(&s_keychain_lock);
    return errSecSuccess;
}

static OSStatus shim_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    pthread_mutex_lock(&s_keychain_lock);
    if (!s_keychain_dict) {
        s_keychain_dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    const void *k = get_key(query);
    const void *v = get_val(attributesToUpdate);
    CFDictionarySetValue(s_keychain_dict, k, v);
    pthread_mutex_unlock(&s_keychain_lock);
    return errSecSuccess;
}

DYLD_INTERPOSE(shim_SecItemAdd, SecItemAdd);
DYLD_INTERPOSE(shim_SecItemCopyMatching, SecItemCopyMatching);
DYLD_INTERPOSE(shim_SecItemDelete, SecItemDelete);
DYLD_INTERPOSE(shim_SecItemUpdate, SecItemUpdate);
