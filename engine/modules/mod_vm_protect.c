#include <sys/mman.h>
#include <mach/mach.h>

#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };
#endif

static void *shim_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    if (flags & (MAP_ANON | MAP_ANONYMOUS)) {
        prot |= (PROT_READ | PROT_WRITE);
    }
    return mmap(addr, len, prot, flags, fd, offset);
}
DYLD_INTERPOSE(shim_mmap, mmap);

static kern_return_t shim_vm_allocate(vm_map_t target_task, vm_address_t *address, vm_size_t size, int flags) {
    kern_return_t kr = vm_allocate(target_task, address, size, flags);
    if (kr == KERN_SUCCESS && address && *address) {
        vm_protect(target_task, *address, size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    }
    return kr;
}
DYLD_INTERPOSE(shim_vm_allocate, vm_allocate);
