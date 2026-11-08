#include <signal.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <string.h>

static void handle_memory_fault(int sig, siginfo_t *info, void *ucontext) {
    uintptr_t addr = (uintptr_t)(info ? info->si_addr : NULL);
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
