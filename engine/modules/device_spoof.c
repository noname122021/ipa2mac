#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <string.h>
#include <dlfcn.h>
#include <errno.h>

#ifndef DEVICE_MODEL
#define DEVICE_MODEL "iPad13,8"
#endif

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static int is_libdyld_caller(void) {
    void *caller = __builtin_return_address(1);
    Dl_info info;
    return (dladdr(caller, &info) && info.dli_fname && strstr(info.dli_fname, "libdyld"));
}

static int copy_spoofed_string(const char *val, void *oldp, size_t *oldlenp) {
    size_t len = strlen(val) + 1;
    if (!oldp) {
        if (oldlenp) *oldlenp = len;
        return 0;
    }
    if (oldlenp && *oldlenp < len) return ENOMEM;
    memcpy(oldp, val, len);
    if (oldlenp) *oldlenp = len;
    return 0;
}

static int shim_uname(struct utsname *uts) {
    if (uts) {
        strncpy(uts->machine, DEVICE_MODEL, sizeof(uts->machine) - 1);
        uts->machine[sizeof(uts->machine) - 1] = '\0';
    }
    return 0;
}
DYLD_INTERPOSE(shim_uname, uname);

static int shim_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (is_libdyld_caller()) {
        return sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    if (name && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0 || strcmp(name, "hw.product") == 0)) {
        return copy_spoofed_string(DEVICE_MODEL, oldp, oldlenp);
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
DYLD_INTERPOSE(shim_sysctlbyname, sysctlbyname);

static int shim_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (is_libdyld_caller()) {
        return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    }
    if (namelen >= 2 && name && name[0] == CTL_HW && (name[1] == HW_MACHINE || name[1] == HW_MODEL)) {
        return copy_spoofed_string(DEVICE_MODEL, oldp, oldlenp);
    }
    return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}
DYLD_INTERPOSE(shim_sysctl, sysctl);
