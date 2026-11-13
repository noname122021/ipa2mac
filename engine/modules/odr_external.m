// odr_external.m — serve On-Demand-Resource content from a folder outside the .app bundle.
//
// Games with ODR asset packs look the content up through the main NSBundle (e.g.
// pathForResource:ofType:inDirectory:@"game") and then open the returned path. This module maps
// <bundle>/<subdir>/... to an external folder, so the bundle never needs to be touched or re-signed.
// A file present in the external folder wins; otherwise the bundle copy is used.
//
// Recipe:
//   [shims]        odr_external = true
//   [odr_external] dir = Library/Application Support/Got/data   ; relative = inside ~/Library/Containers/<bundle id>/Data
//                  subdir = game

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <dirent.h>
#import <fcntl.h>
#import <pwd.h>
#import <stdarg.h>
#import <stdio.h>
#import <unistd.h>

#if !defined(ODR_EXTERNAL_DIR) || !defined(ODR_EXTERNAL_SUBDIR)
#error "odr_external needs [odr_external] dir = ... and subdir = ... in the recipe"
#endif

static char s_prefix[PATH_MAX];   // <bundle>/<subdir>
static size_t s_prefix_len;
static char s_root[PATH_MAX];     // external root, "" = inactive
static NSString *s_subdir;

static bool exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

// If path is under the bundle subdir and the external copy exists, write it to out.
static const char *redirect(const char *path, char *out) {
    if (!path || !s_root[0] || strncmp(path, s_prefix, s_prefix_len) != 0) return path;
    char c = path[s_prefix_len];
    if (c != '\0' && c != '/') return path;
    if (snprintf(out, PATH_MAX, "%s%s", s_root, path + s_prefix_len) >= PATH_MAX) return path;
    return exists(out) ? out : path;
}

// ---- libc interposing (applies to every image except this dylib) ----
static int r_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    char buf[PATH_MAX];
    return open(redirect(path, buf), flags, mode);
}
static FILE *r_fopen(const char *path, const char *mode) {
    char buf[PATH_MAX];
    return fopen(redirect(path, buf), mode);
}
static int r_stat(const char *path, struct stat *st) {
    char buf[PATH_MAX];
    return stat(redirect(path, buf), st);
}
static int r_lstat(const char *path, struct stat *st) {
    char buf[PATH_MAX];
    return lstat(redirect(path, buf), st);
}
static int r_access(const char *path, int m) {
    char buf[PATH_MAX];
    return access(redirect(path, buf), m);
}
static DIR *r_opendir(const char *path) {
    char buf[PATH_MAX];
    return opendir(redirect(path, buf));
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *rep; const void *orig; } s_interpose[] = {
    {(const void *)r_open, (const void *)open},
    {(const void *)r_fopen, (const void *)fopen},
    {(const void *)r_stat, (const void *)stat},
    {(const void *)r_lstat, (const void *)lstat},
    {(const void *)r_access, (const void *)access},
    {(const void *)r_opendir, (const void *)opendir},
};

// ---- NSBundle lookups (main bundle only) ----
static IMP o_pathDir, o_urlDir;

// External path for name.ext in dir (dir == subdir or subdir/...), or nil.
static NSString *external_for(NSBundle *b, NSString *name, NSString *ext, NSString *dir) {
    if (b != [NSBundle mainBundle] || !name || ![dir hasPrefix:s_subdir]) return nil;
    if (dir.length > s_subdir.length && [dir characterAtIndex:s_subdir.length] != '/') return nil;
    NSString *file = ext.length ? [name stringByAppendingPathExtension:ext] : name;
    NSString *p = [[@(s_root) stringByAppendingPathComponent:[dir substringFromIndex:s_subdir.length]]
                   stringByAppendingPathComponent:file];
    return exists(p.fileSystemRepresentation) ? p : nil;
}

static NSString *h_pathDir(NSBundle *self, SEL _cmd, NSString *name, NSString *ext, NSString *dir) {
    NSString *p = external_for(self, name, ext, dir);
    return p ?: ((NSString *(*)(id, SEL, NSString *, NSString *, NSString *))o_pathDir)(self, _cmd, name, ext, dir);
}

static NSURL *h_urlDir(NSBundle *self, SEL _cmd, NSString *name, NSString *ext, NSString *dir) {
    NSString *p = external_for(self, name, ext, dir);
    return p ? [NSURL fileURLWithPath:p]
             : ((NSURL *(*)(id, SEL, NSString *, NSString *, NSString *))o_urlDir)(self, _cmd, name, ext, dir);
}

__attribute__((constructor))
static void init_odr_external(void) {
    @autoreleasepool {
        NSBundle *mb = [NSBundle mainBundle];
        s_subdir = @ODR_EXTERNAL_SUBDIR;
        strlcpy(s_prefix, [mb.bundlePath stringByAppendingPathComponent:s_subdir].fileSystemRepresentation, sizeof(s_prefix));
        s_prefix_len = strlen(s_prefix);

        NSString *root = @ODR_EXTERNAL_DIR;
        if (![root hasPrefix:@"/"]) {
            struct passwd *pw = getpwuid(getuid());
            NSString *home = pw ? @(pw->pw_dir) : NSHomeDirectory();
            root = [home stringByAppendingFormat:@"/Library/Containers/%@/Data/%@", mb.bundleIdentifier, root];
        }
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
            NSLog(@"[ipa2mac] odr_external: %@ not found, using bundle", root);
            return;
        }
        strlcpy(s_root, root.stringByStandardizingPath.fileSystemRepresentation, sizeof(s_root));
        NSLog(@"[ipa2mac] odr_external: %s/* -> %s", s_prefix, s_root);

        o_pathDir = method_setImplementation(class_getInstanceMethod([NSBundle class], @selector(pathForResource:ofType:inDirectory:)), (IMP)h_pathDir);
        o_urlDir = method_setImplementation(class_getInstanceMethod([NSBundle class], @selector(URLForResource:withExtension:subdirectory:)), (IMP)h_urlDir);
    }
}
