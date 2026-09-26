#include <limits.h>

#include <stdint.h>

#include <stdio.h>

static int gcd(int left, int right)
{
    while (right != 0) {
        int remainder = left % right;
        left = right;
        right = remainder;
    }
    return left < 0 ? -left : left;
}

static const char *sign_name(int value)
{
    if (value < 0) {
        return "negative";
    }
    if (value > 0) {
        return "positive";
    }
    return "zero";
}

static void exercise_expressions(int seed)
{
    int value = seed;
    value += 5;
    value -= 2;
    value *= 3;
    value /= 2;
    value %= 7;
    value <<= 2;
    value >>= 1;
    value &= 0x3f;
    value |= 0x10;
    value ^= 0x01;
    int before = value++;
    int after = --value;
    int combined = (value += 2, value * 3);
    unsigned int mask = 0b1010'1010u;
    int shifted = mask >> 2;
    int complement = ~mask;
    int logical = !value || value > 0 && seed != 0;
    int selected = value > 0 ? value : -value;
    printf("%d %d %d %u %d %d %d\n", before, after, combined, mask, shifted, complement, logical);
    printf("%d %s %d\n", selected, sign_name(selected), gcd(selected, seed));
}

int main(void)
{
    signed char tiny = -12;
    unsigned char byte = 250u;
    short small = -1000;
    unsigned short positive = 60000u;
    int integer = -42;
    unsigned int unsigned_integer = 42u;
    long native_long = -100000L;
    unsigned long unsigned_native_long = 100000UL;
    long long wide = -1000000000000LL;
    unsigned long long unsigned_wide = 1000000000000ULL;
    float single = 1.25f;
    double real = 3.141592653589793;
    long double extended = 2.718281828459045L;
    double ratio = (double)small / integer;
    exercise_expressions(integer);
    int total = 0;
    for (int i = 0; i < 10; ++i) {
        if (i % 3 == 0) {
            continue;
        }
        if (i == 8) {
            break;
        }
        total += i;
    }
    int countdown = 3;
    while (countdown > 0) {
        total += countdown;
        --countdown;
    }
    do {
        total *= 2;
    } while (total < 20);
    switch (total % 3) {
        case 0:
        total += 100;
        break;
        case 1:
        total -= 10;
        break;
        default:
        total = 0;
        break;
    }
    printf("%d %u %d %u %u %ld %lu %lld %llu\n", tiny, byte, small, positive, unsigned_integer, native_long, unsigned_native_long, wide, unsigned_wide);
    printf("%.2f %.15Lf %.6f %.6f %d %d\n", single, extended, real, ratio, total, INT_MAX > 0);
    return 0;
}
