#include <pthread.h>

__attribute__((noreturn)) void __assert_rtn(const char *func, const char *file, int line, const char *failedexpr) {
    pthread_exit(NULL);
}
