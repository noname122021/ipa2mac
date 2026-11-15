#include <signal.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <string.h>

static void handle_memory_fault(int sig, siginfo_t *info, void *ucontext) {
    uintptr_t addr = (uintptr_t)(info ? info->si_addr : NULL);
    if (addr < 0x4000) return;
    uintptr_t page = addr & ~0x3fff;
    mprotect((void*)page, 0x10000, PROT_READ | PROT_WRITE);
    vm_protect(mach_task_self(), (vm_address_t)page, 0x10000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}

__attribute__((constructor(101)))
static void init_fault_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handle_memory_fault;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
}
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
#include <signal.h>
#include <stdlib.h>

#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };
#endif

static void shim_abort(void) {}
DYLD_INTERPOSE(shim_abort, abort);

static int shim_raise(int sig) {
    if (sig == SIGABRT || sig == SIGSEGV || sig == SIGBUS) return 0;
    return raise(sig);
}
DYLD_INTERPOSE(shim_raise, raise);

typedef void (*sig_t)(int);
static sig_t shim_signal(int sig, sig_t func) {
    if (sig == SIGSEGV || sig == SIGBUS || sig == SIGABRT || sig == SIGTRAP || sig == SIGILL) return SIG_DFL;
    return signal(sig, func);
}
DYLD_INTERPOSE(shim_signal, signal);

static int shim_sigaction(int sig, const struct sigaction *restrict act, struct sigaction *restrict oact) {
    if (sig == SIGSEGV || sig == SIGBUS || sig == SIGABRT || sig == SIGTRAP || sig == SIGILL) return 0;
    return sigaction(sig, act, oact);
}
DYLD_INTERPOSE(shim_sigaction, sigaction);
