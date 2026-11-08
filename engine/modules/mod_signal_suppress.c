#include <signal.h>
#include <stdlib.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
   __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

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
