#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#define PROGRAM_NAME "Cx declarations"
#define JOIN_INNER(left, right) left##right
#define JOIN(left, right) JOIN_INNER(left, right)
#define STRINGIZE(value) #value
#define PICK(condition, when_true, when_false) \
    ((condition) ? (when_true) : (when_false))
#define LOG(format, ...) printf(format __VA_OPT__(,) __VA_ARGS__)

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define DIALECT 23
#elif defined(__STDC_VERSION__)
#define DIALECT 1
#else
#define DIALECT 0
#endif

#ifndef WIDTH
#define WIDTH 8
#elifdef WIDTH
#define WIDTH_IS_DEFINED 1
#elifndef WIDTH
#define WIDTH_IS_UNDEFINED 1
#endif

#define JOINED JOIN(sample, name)
#define TEXT STRINGIZE(Cx)

static int global_counter = 3;
extern int external_counter;
int external_counter;

static int global_state(void)
{
    static int calls;
    int step = 2;
    ++calls;
    return calls * step;
}

static inline int square(int value)
{
    return value * value;
}

[[nodiscard]] static int checked_value(int value)
{
    return value < 0 ? -value : value;
}

[[maybe_unused]] static _Noreturn void fail(const char *message)
{
    fputs(message, stderr);
    exit(1);
}

static int type_id(int value)
{
    return _Generic(value,
        int: 1,
        long: 2,
        double: 3,
        default: 0
    );
}

static_assert(sizeof(int) >= 2, "int must hold at least 16 bits");
alignas(16) static int aligned_counter [[maybe_unused]];
_Thread_local int per_thread_counter;
constexpr int constant_limit = WIDTH * 2;
volatile int observable_counter;
int *restrict restricted_pointer;

int main(void)
{
    auto inferred = 40 + 2;
    const int local_constant = WIDTH;
    int *restrict local_pointer = &external_counter;
    alignas(2 * sizeof(int)) char aligned_bytes[8] = {};

    *local_pointer = square(inferred);
    ++global_counter;
    ++observable_counter;

    LOG("%s: %d %d %d\n", PROGRAM_NAME, global_counter, external_counter, DIALECT);
    LOG("%s, width=%d, constant=%d, state=%d\n", TEXT, local_constant, constant_limit, global_state());
    printf("generic=%d checked=%d aligned=%zu thread=%d\n",
           type_id(inferred), checked_value(-3), alignof(max_align_t),
           per_thread_counter);

    if (aligned_bytes[0] == '\0' && aligned_bytes[7] == '\0') {
        puts("alignment storage is writable");
    }
    return 0;
}
