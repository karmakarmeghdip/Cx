/*
 * Common GNU C extensions. This file is intentionally compiled as GNU C,
 * not strict ISO C23.
 */

#include <stdio.h>
#include <stdlib.h>

#define GNU_LOG(format, ...) printf(format, ##__VA_ARGS__)
#define COUNTER_VALUE __COUNTER__
#define OLD_STYLE_FIELD(value) { .x = value }

struct empty {};

struct range_initializer {
    int values[8];
};

union converted {
    int integer;
    float real;
};

struct point {
    int x;
    int y;
};

struct packed_record {
    int first;
    int second;
} __attribute__((packed));

struct aligned_record {
    int value;
} __attribute__((aligned(16)));

typedef int vector4 __attribute__((vector_size(16)));

static const char *function_name(void)
{
    return __func__;
}

static const char *pretty_function_name(void)
{
    return __PRETTY_FUNCTION__;
}

__attribute__((noinline))
static int classify_with_range(int value)
{
    switch (value) {
    case 0:
        return 0;
    case 1 ... 5:
        return 1;
    case 6 ... 9:
        return 2;
    default:
        return -1;
    }
}

static int omitted_middle(int value)
{
    int fallback = 9;
    return value ?: fallback;
}

static int legacy_add(a, b)
int a;
int b;
{
    return a + b;
}

static int statement_expression(int value)
{
    return ({
        int doubled = value * 2;
        doubled + 1;
    });
}

static int computed_goto(int value)
{
    static void *labels[] = {&&negative, &&positive};

    goto *labels[value >= 0];

negative:
    return -value;

positive:
    return value;
}

static int nested_function(int value)
{
    __label__ done;
    int helper(int candidate)
    {
        if (candidate < 0) {
            goto done;
        }
        return candidate * 2;
    }

    int result = helper(value);
done:
    return result;
}

static int zero_length_and_empty(void)
{
    struct zero_length {
        int length;
        int data[0];
    } value = {.length = 1};
    struct empty empty = {};
    return value.length + sizeof empty;
}

static int old_field_designator(int value)
{
    struct point point = {x: value};
    return point.x;
}

static int old_and_range_designators(void)
{
    struct range_initializer value = {
        .values[0 ... 2] = 3,
        .values[6 ... 7] = 4,
    };
    return value.values[0] + value.values[6];
}

static int type_builtins(int value)
{
    __auto_type copy = value;
    typeof(copy) reflected = value;
    __typeof__(reflected) another = reflected;
    int selected = __builtin_choose_expr(
        __builtin_types_compatible_p(typeof(copy), int),
        another,
        0);
    return selected + __builtin_constant_p(value ? 1 : 1) + (__alignof__(double) > 0);
}

static int cast_to_union(float value)
{
    union converted result = (union converted)value;
    return result.integer;
}

static int extended_operators(int value)
{
    __int128 wide = (__int128)value << 64;
    void *pointer = &value;
    int arbitrary = value + (pointer - pointer);
    return arbitrary + (int)wide + sizeof(void);
}

static int inline_assembly(int value)
{
    __asm__ volatile ("" : "+r"(value) : : "memory");
    return value;
}

int main(void)
{
    __extension__ int extension_value = 1;
    int selector = classify_with_range(4);
    int expression = ({
        int total = 0;
        for (int index = 0; index < 4; ++index) {
            total += index;
        }
        total;
    });

    GNU_LOG("counter=%d name=%s pretty=%s extension=%d\n",
            COUNTER_VALUE, function_name(), pretty_function_name(), extension_value);
    printf("range=%d middle=%d statement=%d goto=%d nested=%d expression=%d\n",
           selector,
           omitted_middle(0),
           statement_expression(5),
           computed_goto(-3),
           nested_function(6),
           expression);
    printf("empty=%d legacy=%d field=%d designators=%d builtins=%d union=%d extended=%d asm=%d\n",
           zero_length_and_empty(),
           legacy_add(20, 22),
           old_field_designator(8),
           old_and_range_designators(),
           type_builtins(7),
           cast_to_union(1.0f),
           extended_operators(2),
           inline_assembly(3));
    return EXIT_SUCCESS;
}
