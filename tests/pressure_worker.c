// 試験専用の有界負荷。親消滅・75秒・criticalメモリ圧力で自身も終了する。
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

static double now(clockid_t clock) {
    struct timespec value;
    if (clock_gettime(clock, &value)) exit(2);
    return value.tv_sec + value.tv_nsec / 1e9;
}
static uint64_t random_word(uint64_t *value) {
    *value ^= *value << 13; *value ^= *value >> 7; *value ^= *value << 17;
    return *value;
}
static int safe(pid_t parent, double deadline) {
    int level = 0; size_t size = sizeof(level);
    return getppid() == parent && now(CLOCK_MONOTONIC) < deadline &&
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, NULL, 0) == 0 && (level == 1 || level == 2);
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end; unsigned long mib = strtoul(argv[1], &end, 10);
    if (*end || mib > 8192) return 2;
    struct rlimit limit = {80, 80};
    if (setrlimit(RLIMIT_CPU, &limit)) return 2;
    pid_t parent = getppid(); double started = now(CLOCK_MONOTONIC), deadline = started + 75;
    size_t bytes = (size_t)mib * 1024 * 1024;
    uint64_t state = ((uint64_t)getpid() << 32) ^ (uint64_t)(started * 1e9) ^ 0xc47db813;
    volatile uint64_t *memory = NULL;
    if (bytes) {
        size_t requested = bytes;
        memory = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (memory == MAP_FAILED) return 3;
        for (size_t offset = 0; offset < bytes / 8; ++offset) {
            memory[offset] = random_word(&state);
            if ((offset & 0x1fffff) == 0) {
                if (!safe(parent, deadline)) return 4;
                int level = 0; size_t size = sizeof(level);
                if (sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, NULL, 0)) return 4;
                // warningに到達したら増量を止め、既に触ったページだけを維持する。
                if (level == 2 && offset >= 512 * 1024 * 1024 / 8) {
                    bytes = offset * 8;
                    break;
                }
            }
        }
        if (bytes < requested) munmap((char *)memory + bytes, requested - bytes);
    }
    printf("{\"ready\":true,\"pid\":%d,\"allocatedBytes\":%zu}\n", getpid(), bytes); fflush(stdout);
    double last = 0; size_t cursor = 0;
    while (safe(parent, deadline)) {
        if (bytes) {
            // 全ページを再参照し、ゼロページ・単なる仮想アドレス予約にしない。
            for (int i = 0; i < 16384; ++i) {
                memory[cursor] ^= random_word(&state);
                cursor = (cursor + 2048) % (bytes / 8);
            }
            usleep(1000);
        } else {
            for (int i = 0; i < 1000000; ++i) random_word(&state);
        }
        double elapsed = now(CLOCK_MONOTONIC) - started;
        if (elapsed - last >= .5) {
            printf("{\"wall\":%.3f,\"cpu\":%.3f,\"checksum\":%llu}\n", elapsed,
                   now(CLOCK_PROCESS_CPUTIME_ID), (unsigned long long)state);
            fflush(stdout); last = elapsed;
        }
    }
    if (bytes) munmap((void *)memory, bytes);
    return 0;
}
