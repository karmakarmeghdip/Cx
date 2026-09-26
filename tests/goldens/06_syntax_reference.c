#include <complex.h>

#include <fenv.h>

#include <iso646.h>

#include <stdalign.h>

#include <stdarg.h>

#include <stdatomic.h>

#include <stdbool.h>

#include <stdckdint.h>

#include <stddef.h>

#include <stdint.h>

#include <stdio.h>

#include <stdlib.h>

#include <string.h>

#include <threads.h>

#include <uchar.h>

#define EMPTY

#define WIDTH 4

#define IDENTITY(value) (value)

#define STRINGIZE(value) #value

#define JOIN_INNER(left, right) left##right

#define JOIN(left, right) JOIN_INNER(left, right)

#define DIGRAPH_JOIN(left, right) left %:%: right

#define SUM(first, ...) ((first) __VA_OPT__(+ __VA_ARGS__))

#define MULTILINE(first, second) \
    ((first) + (second))

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L

#define DIALECT 202311L

#elifdef WIDTH

#define DIALECT 1

#elifndef WIDTH

#define DIALECT 0

#else

#define DIALECT -1

#endif

#ifdef WIDTH

#define WIDTH_IS_DEFINED 1

#endif

#ifndef MISSING

#define MISSING 0

#endif

#undef EMPTY

#define REDEFINED 1

#if defined(__has_include)

#if __has_include(<stdio.h>)

#define HAS_STDIO 1

#endif

#endif

#if defined(__has_c_attribute)

#if __has_c_attribute(deprecated)

#define HAS_DEPRECATED 1

#endif

#endif

#pragma STDC FP_CONTRACT ON

#if defined(FENV_ROUND) && defined(FENV_DEC_ROUND)

#define HAS_FENV_ROUND_MACROS 1

#endif

#if 0

#warning disabled warning-directive example

#error disabled error-directive example

#endif

#if __has_embed("embed.txt")

static const unsigned char embedded_bytes[] = {
#embed "embed.txt" limit(5)
};

#endif

static const int decimal_integer = 1'000'000;

static const int octal_integer = 0755;

static const int binary_integer = 0b1010'0101;

static const int alternative_tokens = 1 && 2;

static const unsigned long long suffixed_integer = 42uwb;

static const int wide_suffix = 42L;

static const unsigned int unsigned_suffix = 42U;

static const unsigned long long long_long_suffix = 42ULL;

static const float single_suffix = 1.0f;

static const double no_suffix = 1.0;

static const long double long_suffix = 1.0L;

static const double hexadecimal_float = 0x1.fp+3;

static const char newline = '\n';

static const char escaped[] = {'\0', '\a', '\b', '\t', '\v', '\f', '\r', '\\', '\"', '\?'};

static const unsigned char octal_escape = '\101';

static const unsigned char hexadecimal_escape = '\x41';

static const int implementation_defined_multicharacter = 'AB';

static const char8_t utf8_character = u8'A';

static const char16_t utf16_character = u'B';

static const char32_t utf32_character = U'C';

static const wchar_t wide_character = L'D';

static const char narrow_text[] = "abc" "def";

static const char8_t utf8_text[] = u8"é";

static const char16_t utf16_text[] = u"π";

static const char32_t utf32_text[] = U"😀";

static const wchar_t wide_text[] = L"wide";

static const int Ångstrom = 1;

static const int \u00C5ngstromAlias = 2;

static void *const volatile null_pointer = NULL;

#line 120 "preprocessed_syntax_reference.cx"

struct incomplete;

union incomplete_union;

static const volatile int qualified_integer = 1;

static int let = 1;

static int function = 2;

static int type = 3;

static int as = 4;

static int cinit = 5;

static int *const const_pointer = NULL;

const int *volatile pointer_to_volatile_constant = NULL;

int *restrict restrict_pointer = NULL;

static _Atomic(int) atomic_by_constructor;

static _Atomic int atomic_integer;

static volatile int volatile_integer;

static int integer_alias = 1;

typedef int IntegerAlias;

static IntegerAlias typedef_integer = 2;

static const int constant_expression_array[WIDTH];

constexpr int constexpr_integer = 40 + 2;

static thread_local int thread_integer = 3;

static int inferred_integer = 4;

static int *pointer_integer = &inferred_integer;

static int **pointer_pointer_integer = &pointer_integer;

static int fixed_array[4];

static int inferred_array[] = {1, 2, 3};

extern int incomplete_array[];

static int matrix[2][3];

static int *array_of_pointers[4];

static int (*pointer_to_array)[4];

static int (*function_pointer)(int, char *);

static int *returns_pointer(int selector);

static int (*returns_array_pointer(void))[4];

static int (*array_of_function_pointers[3])(int);

static void (*takes_callback(void (*callback)(int)))(int);

static bool boolean_value = true;

static bool false_value = false;

static int bit_int = 42wb;

static unsigned _BitInt(37) unsigned_bit_int = 42uwb;

static typeof(inferred_integer) copied_type = 5;

static typeof_unqual(const int) unqualified_type = 6;

static double _Complex complex_value = 1.0;

static float _Complex imaginary_complex_value = 2.0f;

static long double long_double_value = 1.0L;

static nullptr_t null_typed_value = nullptr;

static ptrdiff_t pointer_size_difference = sizeof(int *);

static size_t object_size = sizeof(struct incomplete *);

alignas(16) static int aligned_integer = 7;

_Alignas(double) static char alignment_bytes[8];

#if defined(__STDC_IEC_60559_DFP__)

static _Decimal32 decimal32_value = 1.0df;

static _Decimal64 decimal64_value = 1.0dd;

static _Decimal128 decimal128_value = 1.0dl;

#endif

static int checked_add(int left, int right)
{
    int result;
    return ckd_add(&result, left, right) ? -1 : result;
}

static int unreachable_value(int value)
{
    if (value < 0) {
        unreachable();
    }
    return value;
}

enum color : unsigned char;

enum color : unsigned char {
    COLOR_RED,
    COLOR_GREEN = 10,
    COLOR_BLUE,
};

enum flags {
    FLAG_NONE [[deprecated]] = 0,
    FLAG_READ = 1 << 0,
    FLAG_WRITE = 1 << 1,
    FLAG_ALL = FLAG_READ | FLAG_WRITE,
};

enum large_enum {
    LARGE_ENUM_VALUE = 0x100000000LL,
};

struct point {
    int x;
    int y;
};

struct bits {
    unsigned int low : 3;
    unsigned : 0;
    signed int high : 5;
    unsigned int ignored : 2;
};

struct nested {
    static_assert(WIDTH == 4);
    struct {
        int left;
        int right;
    };
    union {
        int integer;
        float real;
    };
    int tail;
};

struct buffer {
    size_t length;
    unsigned char bytes[];
};

struct node {
    int value;
    struct node *next;
};

struct containing_record {
    struct point point;
    int tag;
};

struct attributed_record {
    [[maybe_unused]] int before;
    [[maybe_unused]] int after;
};

union scalar {
    int integer;
    float real;
};

static struct point initialized_point = {.y = 2, .x = 1};

static struct nested initialized_nested = {.left = 3, .integer = 4, .tail = 5};

static union scalar initialized_union = {.real = 1.5f};

static int designated_array[8] = {[7] = 7, [2] = 2, [4] = 4};

static int nested_designator[2][3] = {[1][2] = 9};

static int empty_initializers[4] = {};

static struct point empty_point = {};

static const char character_array[4] = {'C', 'x'};

static const char string_array[] = "Cx";

static const struct point *compound_pointer = &(const struct point){.x = 8, .y = 9};

static const int *compound_array = (const int[]){1, 2, 3};

[[nodiscard]] int checked_value(int value);

int unnamed_parameters(int, char *);

[[deprecated ("use checked_value")]] static int function_with_attributes(int value);

void variadic_only(...);

int empty_parameter_prototype(void);

static _Noreturn void terminate_now(void);

static int pointer_parameter(int *values, size_t count);

static int qualified_pointer_parameter(const int *restrict values, size_t count);

static int array_parameter(int values[WIDTH]);

static int qualified_array_parameter(int values[const WIDTH]);

static int static_array_parameter(int values[static WIDTH]);

static size_t variable_array_parameter(int count, int values[count]);

size_t star_array_parameter(int count, int values[*]);

static int matrix_parameter(int count, int values[count][3]);

static int apply_operation(int left, int right, int (*operation)(int, int));

static int generic_identity(const int *value);

static size_t collect_varargs(int count, ...);

[[nodiscard]] int checked_value(int value)
{
    return value < 0 ? -value : value;
}

int unnamed_parameters(int, char *)
{
    return 0;
}

void variadic_only(...)
{}

static int function_with_attributes(int value)
{
    return value;
}

static _Noreturn void terminate_now(void)
{
    exit(1);
}

static int *returns_pointer(int selector)
{
    static int first;
    static int second;
    return selector ? &first : &second;
}

static int (*returns_array_pointer(void))[4]
{
    static int array[2][4];
    return array;
}

static void callback_body(int value)
{
    (void)value;
}

static void (*takes_callback(void (*callback)(int)))(int)
{
    return callback;
}

static int add(int left, int right)
{
    return left + right;
}

static int pointer_parameter(int *values, size_t count)
{
    int total = 0;
    while (count-- != 0) {
        total += *values++;
    }
    return total;
}

static int qualified_pointer_parameter(const int *restrict values, size_t count)
{
    return count == 0 ? 0 : values[0];
}

static int array_parameter(int values[WIDTH])
{
    return values[WIDTH - 1];
}

static int qualified_array_parameter(int values[const WIDTH])
{
    return values[0];
}

static int static_array_parameter(int values[static WIDTH])
{
    return values[0];
}

static size_t variable_array_parameter(int count, int values[count])
{
    (void)values;
    return (size_t)count;
}

static int matrix_parameter(int count, int values[count][3])
{
    int total = 0;
    for (int row = 0; row < count; ++row) {
        total += values[row][2];
    }
    return total;
}

static int apply_operation(int left, int right, int (*operation)(int, int))
{
    return operation(left, right);
}

static int generic_identity(const int *value)
{
    return _Generic(value, int *: 1, const int *: 2, default: 0);
}

static size_t collect_varargs(int count, ...)
{
    va_list arguments;
    va_start(arguments, count);
    int total = 0;
    for (int index = 0; index < count; ++index) {
        total += va_arg(arguments, int);
    }
    va_end(arguments);
    return (size_t)total;
}

static int c23_varargs(int first, ...)
{
    va_list arguments;
    va_start(arguments);
    int second = va_arg(arguments, int);
    va_end(arguments);
    return first + second;
}

static int *static_compound_literal(void)
{
    static int values[] = {3, 4};
    return values;
}

static void statement_expressions(int seed)
{
    int value = seed;
    if (value < 0) {
        value = -value;
    } else if (value == 0) {
        value = 1;
    } else{
        value--;
    }
    switch (value % 3) {
        case 0:
        value += 3;
        break;
        case 1:
        value -= 1;
        [[fallthrough]];
        case 2:
        value *= 2;
        break;
        default:
        value = 0;
    }
    while (value < 10) {
        ++value;
    }
    do {
        --value;
    } while (value > 0);
    for (int index = 0; index < 3; ++index) {
        if (index == 1) {
            continue;
        }
        value += index;
    }
    for (;;) {
        break;
    }
    if (value == 0) {
        goto done;
    }
    done:
    ;
}

static int c23_label_placement(int value)
{
    goto negative;
    negative:
    int result = -value;
    if (result > 10) {
        goto finished;
    }
    ++result;
    finished:
    return result;
}

static void empty_label_at_block_end(void)
{
    goto finished;
    finished:
}

static void expression_productions(void)
{
    int values[WIDTH] = {1, 2, 3, 4};
    int *pointer = values;
    int **pointer_to_pointer = &pointer;
    int (*array_pointer)[WIDTH] = &values;
    int pointer_element = values[2];
    int (*function_pointer_value)(int, char *) = NULL;
    const char *text = "Cx";
    int before_increment = pointer_element++;
    int after_increment = ++pointer_element;
    int negative = -before_increment;
    int positive = +negative;
    int logical_not = !after_increment;
    int bit_not = ~after_increment;
    ptrdiff_t distance = pointer + WIDTH - pointer;
    bool comparison = 0 < after_increment && after_increment <= WIDTH;
    int bit_value = 0x0f & 0x33 | 0x10 ^ 0x01;
    bit_value <<= 1;
    bit_value >>= 1;
    int conditional = comparison ? bit_value : 0;
    int comma = (conditional++, conditional + 1);
    size_t type_size = sizeof(struct point);
    size_t expression_size = sizeof(values);
    size_t unevaluated_size = sizeof(pointer_element);
    size_t alignment = alignof(max_align_t);
    size_t old_alignment = alignof(long double);
    void *null_value = nullptr;
    struct point literal = (struct point){.x = 1, .y = 2};
    int generic = _Generic(pointer_element, int *: 1, default: 0);
    atomic_fetch_add(&atomic_integer, 1);
    atomic_store(&atomic_by_constructor, 2);
    int atomic_value = atomic_load(&atomic_by_constructor);
    (void)pointer_to_pointer;
    (void)array_pointer;
    (void)function_pointer_value;
    (void)text;
    (void)positive;
    (void)logical_not;
    (void)bit_not;
    (void)distance;
    (void)comma;
    (void)unevaluated_size;
    (void)old_alignment;
    (void)null_value;
    (void)literal;
    (void)generic;
    (void)atomic_value;
    (void)alignment;
    (void)type_size;
    (void)expression_size;
}

int main(void)
{
    static_assert(sizeof(int) >= 2);
    static_assert(WIDTH > 0, "width must be positive");
    constexpr int local_limit = 10;
    auto inferred = local_limit + 1;
    int local = inferred;
    int matrix[local_limit][2];
    matrix[0][0] = 42;
    int operation = apply_operation(20, 22, add);
    int collected = (int)collect_varargs(3, 1, 2, 3);
    int (*returned_array)[4] = returns_array_pointer();
    takes_callback(callback_body)(7);
    atomic_init(&atomic_integer, 0);
    statement_expressions(inferred);
    expression_productions();
    printf("%d %d %d %d %d %d %s %s\n", operation, collected, returned_array[0][0], c23_label_placement(-12), local, matrix[0][0], __func__, STRINGIZE(Cx));
    return EXIT_SUCCESS;
}
