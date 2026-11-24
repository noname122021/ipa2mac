// portable_home.m — redirect Documents, Caches, and AppSupport to a portable neighbor folder (<AppName>_Data)
// next to the .app bundle, enabling zero-copy assets and multi-Mac portability on removable drives.
//
// If <parent>/<AppName>_Data exists or parent is writable (and outside /Applications),
// it redirects NSSearchPathForDirectoriesInDomains and NSHomeDirectory to that folder.
// Otherwise, falls back to the standard macOS container (~/Library/Containers/<bundle_id>/Data).

#import <Foundation/Foundation.h>
#import <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static NSString *s_portable_root = nil;

static NSString *shim_NSHomeDirectory(void) {
    return s_portable_root ?: NSHomeDirectory();
}
DYLD_INTERPOSE(shim_NSHomeDirectory, NSHomeDirectory);

static NSArray<NSString *> *shim_NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory dir, NSSearchPathDomainMask mask, BOOL expand) {
    if (s_portable_root && (mask & NSUserDomainMask)) {
        NSString *sub = nil;
        if (dir == NSDocumentDirectory) sub = @"Documents";
        else if (dir == NSCachesDirectory) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *topCaches = [s_portable_root stringByAppendingPathComponent:@"Caches"];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:topCaches isDirectory:&isDir] && isDir) return @[topCaches];
            for (NSString *item in [fm contentsOfDirectoryAtPath:s_portable_root error:nil]) {
                NSString *nested = [[s_portable_root stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Caches"];
                if ([fm fileExistsAtPath:nested isDirectory:&isDir] && isDir) return @[nested];
            }
            sub = @"Library/Caches";
        }
        else if (dir == NSApplicationSupportDirectory) sub = @"Library/Application Support";
        if (sub) {
            NSString *p = [s_portable_root stringByAppendingPathComponent:sub];
            [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
            return @[p];
        }
    }
    return NSSearchPathForDirectoriesInDomains(dir, mask, expand);
}
DYLD_INTERPOSE(shim_NSSearchPathForDirectoriesInDomains, NSSearchPathForDirectoriesInDomains);

__attribute__((constructor))
static void init_portable_home(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        NSString *parent = mb.bundlePath.stringByDeletingLastPathComponent;
        NSString *appName = mb.bundlePath.lastPathComponent.stringByDeletingPathExtension;
        if (!parent || !appName) return;

        NSString *n1 = [parent stringByAppendingPathComponent:[appName stringByAppendingString:@"_Data"]];
        NSString *n2 = [parent stringByAppendingPathComponent:[mb.bundleIdentifier stringByAppendingString:@"_Data"]];
        BOOL isDir = NO;
        NSFileManager *fm = [NSFileManager defaultManager];

        if ([fm fileExistsAtPath:n1 isDirectory:&isDir] && isDir) s_portable_root = [n1 copy];
        else if ([fm fileExistsAtPath:n2 isDirectory:&isDir] && isDir) s_portable_root = [n2 copy];
        else if (![parent hasPrefix:@"/Applications"] && access(parent.fileSystemRepresentation, W_OK) == 0) {
            // shortcut: creates <AppName>_Data next to bundle on writable drives; skip if inside /Applications
            if ([fm createDirectoryAtPath:n1 withIntermediateDirectories:YES attributes:nil error:nil]) {
                s_portable_root = [n1 copy];
            }
        }

        if (s_portable_root) {
            NSLog(@"[ipa2mac] portable_home: data container -> %@", s_portable_root);
        }
    }
}
