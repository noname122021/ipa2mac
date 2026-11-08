#include <mach-o/dyld.h>
#include <stdint.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

typedef void (*dyld_image_func)(const struct mach_header* mh, intptr_t vmaddr_slide);

static void shim_dyld_register_func_for_add_image(dyld_image_func func) {
    // Suppress registration to prevent deadlock in legacy fishhook
}
DYLD_INTERPOSE(shim_dyld_register_func_for_add_image, _dyld_register_func_for_add_image);
