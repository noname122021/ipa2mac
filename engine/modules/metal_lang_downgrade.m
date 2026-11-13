// metal_lang_downgrade.m — lower the shader language version tags in metallibs when the running
// macOS cannot compile them (iOS 18 SDK shaders are MSL 3.2 / AIR 2.7, macOS 14 tops out at 3.1 / 2.6).
// On macOS 15+ nothing is hooked. IPA2MAC_MSL_DOWNGRADE=0 disables.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

// {MSL major, minor, AIR major, minor}, newest first; index 0 needs macOS 15, 1 needs 14, ...
static const uint16_t kVers[][4] = {{3, 2, 2, 7}, {3, 1, 2, 6}, {3, 0, 2, 5}, {2, 4, 2, 4}};
#define NVERS (int)(sizeof(kVers) / sizeof(kVers[0]))
static int s_max;   // index of the newest version this macOS supports

// Rewrite VERS tags in the MTLB function list. Returns the number of tags changed.
static int patch_metallib(uint8_t *p, size_t n) {
    if (n < 0x28 || memcmp(p, "MTLB", 4) != 0) return 0;
    uint64_t off, size;
    memcpy(&off, p + 0x18, 8);
    memcpy(&size, p + 0x20, 8);           // excludes the leading 4-byte count
    if (off + 4 > n) return 0;
    uint32_t count;
    memcpy(&count, p + off, 4);
    size_t pos = off + 4, end = MIN(n, off + 4 + size);
    int changes = 0;
    for (uint32_t f = 0; f < count && pos + 4 <= end; f++) {
        uint32_t esize;
        memcpy(&esize, p + pos, 4);
        if (esize < 4 || pos + esize > end) break;
        for (size_t t = pos + 4; t + 6 <= pos + esize && memcmp(p + t, "ENDT", 4); ) {
            uint16_t len = p[t + 4] | (p[t + 5] << 8);
            if (len == 8 && !memcmp(p + t, "VERS", 4) && t + 14 <= pos + esize) {
                uint16_t *v = (uint16_t *)(p + t + 6);   // air maj, air min, lang maj, lang min
                for (int i = 0; i < s_max; i++) {
                    if (v[2] == kVers[i][0] && v[3] == kVers[i][1]) {
                        v[0] = kVers[s_max][2]; v[1] = kVers[s_max][3];
                        v[2] = kVers[s_max][0]; v[3] = kVers[s_max][1];
                        changes++;
                        break;
                    }
                }
            }
            t += 6 + len;
        }
        pos += esize;
    }
    return changes;
}

static IMP o_data, o_url, o_file;

static id call_data(id self, dispatch_data_t d, NSError **err) {
    return ((id (*)(id, SEL, dispatch_data_t, NSError **))o_data)(self, @selector(newLibraryWithData:error:), d, err);
}

// Returns a patched copy, or nil if nothing needed changing.
static dispatch_data_t patched(const void *buf, size_t sz) {
    uint8_t *copy = malloc(sz);
    memcpy(copy, buf, sz);
    int ch = patch_metallib(copy, sz);
    if (!ch) { free(copy); return nil; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ NSLog(@"[ipa2mac] metal_lang_downgrade: lowering shaders to MSL %u.%u", kVers[s_max][0], kVers[s_max][1]); });
    return dispatch_data_create(copy, sz, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
}

static id h_data(id self, SEL _cmd, dispatch_data_t data, NSError **err) {
    const void *buf = NULL; size_t sz = 0;
    dispatch_data_t map = data ? dispatch_data_create_map(data, &buf, &sz) : nil;
    dispatch_data_t p = buf ? patched(buf, sz) : nil;
    (void)map;
    return call_data(self, p ?: data, err);
}

static id from_file(id self, NSString *path, NSError **err) {
    NSData *d = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
    dispatch_data_t p = d ? patched(d.bytes, d.length) : nil;
    return p ? call_data(self, p, err) : nil;
}

static id h_url(id self, SEL _cmd, NSURL *url, NSError **err) {
    id r = from_file(self, url.isFileURL ? url.path : nil, err);
    return r ?: ((id (*)(id, SEL, NSURL *, NSError **))o_url)(self, _cmd, url, err);
}

static id h_file(id self, SEL _cmd, NSString *path, NSError **err) {
    id r = from_file(self, path, err);
    return r ?: ((id (*)(id, SEL, NSString *, NSError **))o_file)(self, _cmd, path, err);
}

__attribute__((constructor))
static void init_metal_lang_downgrade(void) {
    const char *e = getenv("IPA2MAC_MSL_DOWNGRADE");
    if (e && !atoi(e)) return;
    NSInteger major = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion;
    s_max = (int)MIN(MAX(15 - major, 0), NVERS - 1);   // 15 -> 0, 14 -> 1, 13 -> 2, ...
    if (s_max == 0) return;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return;
    Class k = object_getClass(dev);
    o_data = method_setImplementation(class_getInstanceMethod(k, @selector(newLibraryWithData:error:)), (IMP)h_data);
    o_url  = method_setImplementation(class_getInstanceMethod(k, @selector(newLibraryWithURL:error:)), (IMP)h_url);
    o_file = method_setImplementation(class_getInstanceMethod(k, @selector(newLibraryWithFile:error:)), (IMP)h_file);
}
