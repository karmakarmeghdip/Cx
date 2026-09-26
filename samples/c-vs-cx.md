# C vs. Cx Syntax

Cx is a thin syntactic layer over C. It keeps C's expressions, control flow, pointer operations, aggregate layout, and preprocessor model, while adding a more TypeScript-like surface for declarations, functions, type aliases, casts, and callback types.

The examples in this document describe the syntax currently demonstrated in this repository. The target language is C23, with common GCC extensions isolated in the GNU example.

## Contents

- [Design goals](#design-goals)
- [Quick reference](#quick-reference)
- [Comments and preprocessing](#comments-and-preprocessing)
- [Variables and storage classes](#variables-and-storage-classes)
- [Pointers, arrays, and derived types](#pointers-arrays-and-derived-types)
- [Functions](#functions)
- [Structs, unions, and typedefs](#structs-unions-and-typedefs)
- [Initializers](#initializers)
- [Expressions and casts](#expressions-and-casts)
- [Control flow](#control-flow)
- [C23 syntax](#c23-syntax)
- [Common complete examples](#common-complete-examples)
- [Parser-sensitive rules](#parser-sensitive-rules)
- [Recommended grammar shape](#recommended-grammar-shape)
- [Example files](#example-files)

## Design goals

Cx attempts to provide four properties:

1. **C semantics remain unchanged.** A valid Cx construct should lower to a C construct with the same observable behavior.
2. **Common declarations look modern.** Variables, functions, aliases, and callbacks use `let`, `function`, `type`, and arrow syntax.
3. **C expressions remain familiar.** Arithmetic, pointers, indexing, member access, operators, `sizeof`, and `_Generic` keep C forms; casts and aggregate literals use the small Cx syntax layer described below.
4. **The grammar is regular.** Required semicolons, distinct `[...]` array and `{...}` record literals, ordered type suffixes, and raw identifiers remove common parsing ambiguities.

## Quick reference

| Concern | C | Cx |
|---|---|---|
| Object declaration | `int value = 0;` | `let value: int = 0;` |
| Constant binding | `const int value = 0;` | `const value: int = 0;` |
| Inferred declaration | `auto value = 0;` | `let value = 0;` |
| Function | `int add(int a, int b) { ... }` | `function add(a: int, b: int): int { ... }` |
| Prototype | `int add(int a, int b);` | `function add(a: int, b: int): int;` |
| Typedef | `typedef int Integer;` | `type Integer = int;` |
| Pointer | `int *value;` | `let value: int*;` |
| Pointer to array | `int (*row)[4];` | `let row: int[4]*;` |
| Array of pointers | `int *rows[4];` | `let rows: int*[4];` |
| Function pointer | `int (*fn)(int);` | `let fn: ((int) => int)*;` |
| Cast | `(float)value` | `value as float` |
| Struct field | `struct Point { int x; };` | `struct Point { x: int; };` |
| Struct type use | `struct Point point;` | `let point: struct Point;` |
| Array initializer | `int values[2] = {1, 2};` | `let values: int[2] = [1, 2];` |
| Struct initializer | `struct Point p = {1, 2};` | `let p: struct Point = {x: 1, y: 2};` |
| C designator | `{.x = 1}` | `cinit {.x = 1}` |
| Array compound literal | `(int[]){1, 2}` | `(int[])[1, 2]` |
| Struct compound literal | `(struct Point){.x = 1}` | `(struct Point){x: 1}` |
| Cast to void | `(void)value` | `value as void` |
| Static function | `static int f(void);` | `static function f(): int;` |
| Raw new keyword | `int let = 1;` | `let @let: int = 1;` |

## Comments and preprocessing

### Comments

Comments are unchanged.

```c
// Single-line comment
/* Multi-line comment */
```

```cx
// Single-line comment
/* Multi-line comment */
```

### Includes and directives

Preprocessor directives are retained as C directives; they are not interpreted by the Cx grammar.

A logical line beginning with `#` (after C line-splicing) is handled like a comment by the Cx parser and emitted unchanged. The Cx parser does not macro-expand directives or use their replacement lists to build its AST.

```c
#include <stdio.h>
#include "local.h"

#if defined(FEATURE)
#define FEATURE_VALUE 1
#else
#define FEATURE_VALUE 0
#endif

int enabled = FEATURE_VALUE;
```

```cx
#include <stdio.h>
#include "local.h"

#if defined(FEATURE)
#define FEATURE_VALUE 1
#else
#define FEATURE_VALUE 0
#endif

let enabled: int = FEATURE_VALUE;
```

The parser still reads the non-directive source in both conditional branches, so those branches must be valid Cx. Prefer expressing the conditional choice in a raw C macro value, as above, rather than duplicating Cx declarations in mutually exclusive branches.

`_Pragma` is a C preprocessor operator rather than a `#` directive. It is not interpreted by the current Cx grammar and should be treated as raw C compatibility syntax or as a future extension. A bare macro identifier at file scope is likewise not a Cx external declaration.

Included C headers remain opaque to the Cx parser. Their declarations are already C and are copied to the output through the retained `#include` directives. The parser must not attempt to parse the contents of an included C header as Cx source.

### Macros

Macro replacement lists are raw C token sequences. They must not contain Cx keywords or new Cx syntax.

```c
#define SQUARE(value) ((value) * (value))
#define JOIN_INNER(left, right) left##right
#define JOIN(left, right) JOIN_INNER(left, right)
```

```cx
#define SQUARE(value) ((value) * (value))
#define JOIN_INNER(left, right) left##right
#define JOIN(left, right) JOIN_INNER(left, right)
```

A macro that produces a declaration must contain C syntax:

```c
#define DEFINE_TOTAL int total = 10
```

```cx
#define DEFINE_TOTAL int total = 10
```

Do not use `DEFINE_TOTAL` as a Cx declaration and do not write a replacement list such as `let total: int = 10`; the replacement list is not parsed and lowered. If a macro must be understood by the Cx type checker, it should be implemented as a future language extension rather than as a preprocessor macro.

Macro invocations in ordinary Cx expressions are safe only when their eventual C expansion is valid in that position. The Cx parser treats the invocation as ordinary syntax and does not inspect the expansion.

## Variables and storage classes

### Explicit scalar declarations

```c
int count = 0;
unsigned int mask = 0xffu;
double ratio = 1.0;
```

```cx
let count: int = 0;
let mask: unsigned int = 0xffu;
let ratio: double = 1.0;
```

### Constant bindings and type qualifiers

`const` in declaration position describes the binding. A type-level `const` qualifies the type.

```c
const int limit = 10;
const char *name = "Cx";
char *const fixed_pointer = buffer;
const int *const fixed_const_pointer = values;
```

```cx
const limit: int = 10;
let name: const char* = "Cx";
let fixed_pointer: char* const = buffer;
let fixed_const_pointer: const int* const = values;
```

These forms can be combined:

```c
const char *const name = "Cx";
```

```cx
const name: const char* const = "Cx";
```

`let` does not mean “never reassigned.” It lowers to an ordinary C declaration. `const` requests C const qualification.

### Multiple declarators

Each binding repeats its own type. There is no shared trailing-type sugar:
`let first, second: int` is rejected.

```c
int first = 1, second = 2;
const int third = 3, fourth = 4;
```

```cx
let first: int = 1, second: int = 2;
const third: int = 3, fourth: int = 4;
```

A declaration without an initializer remains uninitialized, as in C.

```c
int value;
double reading;
```

```cx
let value: int;
let reading: double;
```

### Type inference

C23 `auto` declarations use inferred `let` declarations in Cx.

```c
auto count = 10;
auto ratio = 1.5;
```

```cx
let count = 10;
let ratio = 1.5;
```

Explicit annotations are preferable when the exact C type matters. Inference lowers to C23 `auto`, not to an older compiler-specific type deduction feature.

### Storage classes

| C | Cx |
|---|---|
| `static int value;` | `static let value: int;` |
| `extern int value;` | `extern let value: int;` |
| `_Thread_local int value;` | `thread_local let value: int;` |
| `constexpr int value = 1;` | `constexpr let value: int = 1;` |

`constexpr` is a specifier, not a binding introducer: it prefixes `let`/`const`
like `static`/`extern`. `register` and `auto` are not Cx keywords — `register`
is rejected (remove it), and C23 `auto` inference is spelled as `let` without
an annotation (`let count = 10;`).

Storage-class and alignment specifiers may appear before the binding keyword.

```c
alignas(16) static int cache[4];
```

```cx
alignas(16) static let cache: int[4];
```

## Pointers, arrays, and derived types

Cx uses ordered postfix type constructors. Each suffix is applied from left to right.

```text
int             -> int
int*            -> pointer to int
int[4]          -> array of 4 int
int[4]*         -> pointer to array of 4 int
int*[4]         -> array of 4 pointers to int
```

### Pointer forms

```c
int *pointer;
int **pointer_to_pointer;
int *array_of_pointers[4];
int (*pointer_to_array)[4];
```

```cx
let pointer: int*;
let pointer_to_pointer: int**;
let array_of_pointers: int*[4];
let pointer_to_array: int[4]*;
```

The pointer-to-array form is deliberately different from the C declarator:

```c
int (*row)[4];   /* row is a pointer to array */
int *rows[4];    /* rows is an array of pointers */
```

```cx
let row: int[4]*;
let rows: int*[4];
```

### Const and restrict placement

```c
const int *pointer_to_constant;
int *const constant_pointer;
const int *const constant_pointer_to_constant;
int *restrict restricted_pointer;
```

```cx
let pointer_to_constant: const int*;
let constant_pointer: int* const;
let constant_pointer_to_constant: const int* const;
let restricted_pointer: int* restrict;
```

### Array parameter contracts

C array parameters are adjusted to pointer parameters, but qualifiers and `static` retain contractual meaning.

```c
void sum(int values[static 4]);
void reverse(int values[restrict static 4]);
```

```cx
function sum(values: int[static 4]): void;
function reverse(values: int[restrict static 4]): void;
```

Variable-length and variably modified forms remain available:

```c
void fill(int count, int values[count]);
void matrix(int rows, int values[rows][3]);
```

```cx
function fill(count: int, values: int[count]): void;
function matrix(rows: int, values: int[rows][3]): void;
```

## Functions

### Definitions and prototypes

```c
int add(int left, int right)
{
    return left + right;
}

int subtract(int left, int right);
```

```cx
function add(left: int, right: int): int
{
    return left + right;
}

function subtract(left: int, right: int): int;
```

Every `function` declaration states its return type explicitly (`: T` is
required, including `: void`). There is no implicit-int or omitted-return form.

### Void and no-parameter functions

```c
void reset(void);
int answer(void);
```

```cx
function reset(): void;
function answer(): int;
```

Under C23, `()` is a no-parameter prototype. If support for pre-C23 unspecified parameter lists is added, it should use a separate legacy form rather than silently changing C23 semantics.

### Unnamed and variadic parameters

```c
int ignored(int, char *);
int sum(int count, ...);
void variadic_only(...);
```

```cx
function ignored(int, char*): int;
function sum(count: int, ...): int;
function variadic_only(...): void;
```

### Function specifiers and attributes

```c
static inline int square(int value) { return value * value; }
[[nodiscard]] int checked(int value);
[[noreturn]] void terminate(void);
```

```cx
static inline function square(value: int): int { return value * value; }
[[nodiscard]] function checked(value: int): int;
[[noreturn]] function terminate(): void;
```

### Functions returning derived types

```c
int *choose(int flag);
int (*choose_array(void))[4];
```

```cx
function choose(flag: int): int*;
function choose_array(): int[4]*;
```

### Function pointer types

An arrow type describes a function type. A function pointer adds the explicit postfix `*`.

```c
typedef int (*BinaryOperation)(int, int);
int apply(int left, int right, int operation(int, int));
```

```cx
type BinaryOperation = ((int, int) => int)*;
function apply(left: int, right: int, operation: ((int, int) => int)*): int;
```

A bare arrow type is a function type and may be used where a type is expected, but an object binding for a callable value uses the explicit pointer form (`((int) => int)*`). A function parameter declared with a function type receives the same adjustment as C.

Function designators can be assigned and called through Cx's ordinary call syntax:

```c
int (*operation)(int, int) = add;
int result = operation(2, 3);
```

```cx
let operation: ((int, int) => int)* = add;
let result: int = operation(2, 3);
```

## Structs, unions, and typedefs

### Struct fields

Cx moves the type after the field name.

```c
struct Point {
    int x;
    int y;
};
```

```cx
struct Point {
    x: int;
    y: int;
};
```

### Keep C-style tags in type positions

C keeps struct tags and typedef names in separate namespaces, and Cx preserves that behavior. A named record declaration does not create a bare `Point` type.

```c
struct Point point;
struct Point *pointer;
```

```cx
let point: struct Point;
let pointer: struct Point*;
```

### Type aliases

```c
typedef int Integer;
typedef struct Point PointAlias;
```

```cx
type Integer = int;
type PointAlias = struct Point;
```

Anonymous structs have no tag name, so they must be wrapped in an alias when a reusable type name is wanted:

```c
typedef struct {
    int width;
    int height;
} Rectangle;
```

```cx
type Rectangle = struct {
    width: int;
    height: int;
};
```

### Recursive structs

```c
struct Node {
    int value;
    struct Node *next;
};

struct Node *first;
```

```cx
struct Node {
    value: int;
    next: struct Node*;
};

let first: struct Node*;
```

This is intentionally one-to-one with C: the `struct` tag remains explicit, and a typedef is required if a bare `Node` type name is desired.

### Unions and bit-fields

```c
union Scalar {
    int integer;
    float real;
};

struct Bits {
    unsigned low : 3;
    unsigned : 0;
    signed high : 5;
};
```

```cx
union Scalar {
    integer: int;
    real: float;
};

struct Bits {
    low: unsigned int: 3;
    : 0;
    high: signed int: 5;
};
```

The second colon in a Cx bit-field is not the field type separator. The member
parser handles it as an optional width after the type, only in that context:

```text
named-bit-field   = identifier ":" type ":" constant-expression ";"
unnamed-bit-field = ":" constant-expression ";"
```

### Anonymous members and flexible arrays

```c
struct Outer {
    struct {
        int left;
        int right;
    };
};

struct Buffer {
    size_t length;
    unsigned char data[];
};
```

```cx
struct Outer {
    struct {
        left: int;
        right: int;
    };
};

struct Buffer {
    length: size_t;
    data: unsigned char[];
};
```

Aggregate definitions should end with a semicolon consistently.

## Initializers

### Scalar, array, and record initializers

Cx uses expressions for scalar initialization, brackets for arrays, and named-field braces for structs and unions.

```c
int scalar = 1;
int values[3] = {1, 2, 3};
int matrix[2][2] = {{1, 2}, {3, 4}};
struct Point point = {1, 2};
```

```cx
let scalar: int = 1;
let values: int[3] = [1, 2, 3];
let matrix: int[2][2] = [[1, 2], [3, 4]];
let point: struct Point = {x: 1, y: 2};
```

The opening token is selected by parser context: `[` introduces an array type suffix, array literal, or index expression; `[[` (one token) introduces an attribute; `{` introduces a record literal or a statement block.

Lowering is structural: `[1, 2]` becomes C `{1, 2}`, while `{x: 1, y: 2}` becomes C `{.x = 1, .y = 2}`. Nested literals are lowered recursively, preserving field order and anonymous-member semantics.

### String initializers

```c
char text[] = "Cx";
char fixed[8] = "Cx";
const char *pointer = "Cx";
```

```cx
let text: char[] = "Cx";
let fixed: char[8] = "Cx";
let pointer: const char* = "Cx";
```

### C designators and positional records

The normal Cx record literal is named and does not need C designators. Positional records, reordered C designators, sparse array designators, and embedded resources use the explicit `cinit` escape hatch.

```c
struct Point point = {.x = 1, .y = 2};
int values[8] = {[7] = 7, [2] = 2};
int nested[2][3] = {[1][2] = 9};
```

```cx
let point: struct Point = {x: 1, y: 2};
let values: int[8] = cinit {[7] = 7, [2] = 2};
let nested: int[2][3] = cinit {[1][2] = 9};
```

`cinit` lowers its contents as a C initializer and is intended for compatibility rather than everyday Cx style.

### Compound literals

Compound literals use a parenthesized Cx type followed by any initializer.
They are parsed separately from casts (`as` is postfix, compounds start with
`"(" type ")"`, so the two never collide).

```c
struct Point origin = (struct Point){.x = 0, .y = 0};
int *values = (int[]){1, 2, 3};
int *sparse = (int[]){[2] = 2};
```

```cx
let origin: struct Point = (struct Point){x: 0, y: 0};
let values: int* = (int[])[1, 2, 3];
let sparse: int* = (int[])cinit {[2] = 2};
```

### Empty initializers

```c
int values[4] = {};
struct Point point = {};
```

```cx
let values: int[4] = [];
let point: struct Point = {};
```

## Expressions and casts

### Operators

Cx retains C operators and precedence:

```c
a + b * c
a << 2 | flags & mask
condition ? left : right
*pointer++
value = other, 10
```

```cx
a + b * c
a << 2 | flags & mask
condition ? left : right
*pointer++
value = other, 10
```

### Casts

C prefix casts become postfix `as` casts. `as` is a postfix loop, left-folded:
`x as T1 as T2` means `(x as T1) as T2`. It binds tighter than `*`/`/`/`%`
and looser than unary/postfix (`[]`, `.`, `->`, calls, `++`/`--`).

```c
float result = (float)left / right;
double promoted = (double)value;
char character = (char)number;
unsigned char byte = (unsigned char)257;
(void)value;
```

```cx
let result: float = (left as float) / right;
let promoted: double = value as double;
let character: char = number as char;
let byte: unsigned char = 257 as unsigned char;
value as void;
```

`as` is a cast, not a checked TypeScript-style type assertion. It should lower to a C cast and retain C conversion constraints.

Chaining is left-associative (`x as int as float` lowers to `((float)((int)x))`).
The conversion target ends at the first token that cannot continue a type. Mixed
arithmetic must still be parenthesized so the type parser cannot consume a
following identifier as a typedef name:

```c
float result = ((float)left) / right;
```

```cx
let result: float = (left as float) / right;
```

Prefix `(Type)value` casts do not exist in Cx. Parenthesized type expressions are
compound literals — `"(" type ")" initializer`, where `initializer` is reused
(`[...]`, `{...}`, `cinit {...}`, or empty) — plus arrow function types
(`((int) => int)*`).

### `sizeof` and `alignof`

Cx requires parentheses unconditionally: `sizeof "(" (type | expression) ")"`,
`alignof "(" type ")"`. Bare `sizeof expression` (valid C) is rejected; this
removes one prefix arity and keeps a single rule shape.

```c
size_t type_size = sizeof(int);
size_t object_size = sizeof(value);
size_t expression_size = sizeof values;
size_t alignment = alignof(max_align_t);
```

```cx
let type_size: size_t = sizeof(int);
let object_size: size_t = sizeof(value);
let expression_size: size_t = sizeof(values);
let alignment: size_t = alignof(max_align_t);
// sizeof values;  -- rejected, write sizeof(values)
```

`sizeof(T)` and `sizeof(expression)` cannot always be distinguished lexically. If `T` may be either a typedef name or an object name, the parser needs a symbol-table predicate. A pure context-free PEG cannot guarantee C-compatible parsing. The parentheses requirement does not remove this lookup; it only gives the lookup a single syntactic shape.

### Generic selection

```c
int result = _Generic(value,
    int: 1,
    const char *: 2,
    default: 0
);
```

```cx
let result: int = _Generic(value,
    int: 1,
    const char*: 2,
    default: 0
);
```

The colon after a `_Generic` association type is separate from struct-field and bit-field colon productions.

## Control flow

Selection, iteration, jumps, labels, and expression statements retain C syntax.

```c
if (value > 0) {
    run();
} else {
    stop();
}

while (count > 0) {
    --count;
}

do {
    step();
} while (ready);

for (int index = 0; index < 4; ++index) {
    consume(index);
}

switch (value) {
case 0:
    zero();
    break;
default:
    other();
    break;
}

done:
    return;
```

```cx
if (value > 0) {
    run();
} else {
    stop();
}

while (count > 0) {
    --count;
}

do {
    step();
} while (ready);

for (let index: int = 0; index < 4; ++index) {
    consume(index);
}

switch (value) {
case 0:
    zero();
    break;
default:
    other();
    break;
}

done:
    return;
```

A `let` declaration in a `for` initializer omits its normal semicolon because the first semicolon already belongs to the `for` header.

## C23 syntax

Most C23 lexical and statement forms are unchanged.

| Feature | C | Cx |
|---|---|---|
| Boolean type | `bool ready = true;` | `let ready: bool = true;` |
| Null pointer constant | `void *p = nullptr;` | `let p: void* = nullptr;` |
| Binary literal | `int value = 0b1010'0101;` | `let value: int = 0b1010'0101;` |
| Digit separators | `int value = 1'000'000;` | `let value: int = 1'000'000;` |
| `typeof` | `typeof(value) copy = value;` | `let copy: typeof(value) = value;` |
| `typeof_unqual` | `typeof_unqual(const int) x = 1;` | `let x: typeof_unqual(const int) = 1;` |
| `constexpr` | `constexpr int n = 4;` | `constexpr let n: int = 4;` |
| `register` / `auto` | `register int r = 0;` / `auto x = 1;` | rejected / `let x = 1;` |

Like `sizeof`, `typeof` / `typeof_unqual` require parentheses in Cx:
`typeof "(" (type | expression) ")"`. Bare `typeof expr` is rejected.
| Alignment declaration | `alignas(16) int x;` | `alignas(16) let x: int;` |
| Alignment operator | `alignof(T)` | `alignof(T)` |
| Complex type | `double _Complex z;` | `let z: double _Complex;` |
| Atomic type | `_Atomic int counter;` | `let counter: _Atomic int;` |
| Fixed enum type | `enum E : unsigned char { A };` | unchanged |
| Empty initializer | `int a[2] = {};` | `let a: int[2] = [];` |
| UTF-8 string | `char8_t text[] = u8"é";` | `let text: char8_t[] = u8"é";` |
| Attributes | `[[nodiscard]] int f(void);` | `[[nodiscard]] function f(): int;` |
| `static_assert` | `static_assert(sizeof(int) >= 2);` | unchanged |
| `#embed` | `#embed "file.bin"` | `cinit` block containing a standalone `#embed` line |
| C23 `va_start` | `va_start(arguments);` | unchanged |

`#embed` must stay on its own logical line inside a Cx `cinit` block:

```cx
static const bytes: const unsigned char[] = cinit {
#embed "file.bin"
};
```

### Bit-precise integers

```c
_BitInt(37) small = 42wb;
unsigned _BitInt(37) unsigned_small = 42uwb;
```

```cx
let small: _BitInt(37) = 42wb;
let unsigned_small: unsigned _BitInt(37) = 42uwb;
```

### Attributes on enumerators and fields

```c
enum Mode {
    DEFAULT [[deprecated]] = 0,
    FAST = 1
};

struct Record {
    [[maybe_unused]] int before;
    int after [[maybe_unused]];
};
```

```cx
enum Mode {
    DEFAULT [[deprecated]] = 0,
    FAST = 1
};

struct Record {
    [[maybe_unused]] before: int;
    after: int [[maybe_unused]];
};
```

## Common complete examples

### Command-line greeting

#### C

```c
#include <stdio.h>

static void greet(const char *name)
{
    printf("Hello, %s!\n", name);
}

int main(int argc, char **argv)
{
    const char *name = argc > 1 ? argv[1] : "world";
    char initial = name[0];

    greet(name);
    printf("First character: %c\n", initial);
    return 0;
}
```

#### Cx

```cx
#include <stdio.h>

static function greet(name: const char*): void
{
    printf("Hello, %s!\n", name);
}

function main(argc: int, argv: char**): int
{
    let name: const char* = argc > 1 ? argv[1] : "world";
    let initial: char = name[0];

    greet(name);
    printf("First character: %c\n", initial);
    return 0;
}
```

### Record and callback

#### C

```c
#include <stdio.h>

struct Point {
    int x;
    int y;
};

typedef int (*BinaryOperation)(int, int);

static int add(int left, int right) { return left + right; }
static int multiply(int left, int right) { return left * right; }

static int apply(int left, int right, BinaryOperation operation)
{
    return operation(left, right);
}

int main(void)
{
    struct Point point = {.x = 3, .y = 4};
    BinaryOperation operation = point.x > 0 ? add : multiply;

    printf("%d\n", apply(6, 7, operation));
    return 0;
}
```

#### Cx

```cx
#include <stdio.h>

struct Point {
    x: int;
    y: int;
};

type BinaryOperation = ((int, int) => int)*;

static function add(left: int, right: int): int { return left + right; }
static function multiply(left: int, right: int): int { return left * right; }

static function apply(left: int, right: int, operation: BinaryOperation): int
{
    return operation(left, right);
}

function main(): int
{
    let point: struct Point = {x: 3, y: 4};
    let operation: BinaryOperation = point.x > 0 ? add : multiply;

    printf("%d\n", apply(6, 7, operation));
    return 0;
}
```

### Checked dynamic-array growth

#### C

```c
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    size_t count = 4;
    int *values = calloc(count, sizeof *values);

    if (values == NULL) {
        return 1;
    }

    int *grown = realloc(values, 8 * sizeof *values);
    if (grown == NULL) {
        free(values);
        return 1;
    }
    values = grown;

    for (size_t index = 0; index < 8; ++index) {
        values[index] = (int)index;
    }

    printf("%d %d\n", values[0], values[7]);
    free(values);
    return 0;
}
```

#### Cx

```cx
#include <stdio.h>
#include <stdlib.h>

function main(): int
{
    let count: size_t = 4;
    let values: int* = calloc(count, sizeof(*values));

    if (values == NULL) {
        return 1;
    }

    let grown: int* = realloc(values, 8 * sizeof(*values));
    if (grown == NULL) {
        free(values);
        return 1;
    }
    values = grown;

    for (let index: size_t = 0; index < 8; ++index) {
        values[index] = index as int;
    }

    printf("%d %d\n", values[0], values[7]);
    free(values);
    return 0;
}
```

## Parser-sensitive rules

The following rules are important for a recursive-descent implementation.

### 1. Parse Cx keywords as whole tokens

`let`, `function`, `type`, `as`, and `cinit` must not match prefixes of identifiers such as `letter`, `function_pointer`, or `type_name`.

Because these words are valid identifiers in C, Cx uses `@` only when a source identifier collides with a Cx keyword. In `let @let: int = 1`, `@let` is one literal identifier named `let`; it is not a type or a new declaration form.

```c
int let = 1;
int function = 2;
int type = 3;
int as = 4;
int cinit = 5;
```

```cx
let @let: int = 1;
let @function: int = 2;
let @type: int = 3;
let @as: int = 4;
let @cinit: int = 5;
```

The `@` sigil lowers away and is not emitted to C.

### 2. Use one ordered suffix loop for derived types

Do not parse all pointers first and arrays second. Mixed derivations are legal:

```text
int
int*
int[4]
int[4]*
int*[4]
((int) => int)*
((int) => int)*[3]
```

A regular type parser is:

```text
type             = type-qualifier* atomic-specifier? type-base type-suffix*
type-suffix      = "*" (type-qualifier | "_Atomic")*
                 | array-suffix
array-suffix     = "[" (type-qualifier | "_Atomic")* "static"?
                   (type-qualifier | "_Atomic")* expression? "]"
                 | "[" (type-qualifier | "_Atomic")* "*" "]"
type-qualifier    = "const" | "volatile" | "restrict"
atomic-specifier  = "_Atomic"
```

The selected suffix order is significant and must match the type printer. The lexer
emits `[[` and `]]` as single tokens, so after a type the disambiguation is
one token: `[[` begins an attribute, single `[` begins an array suffix.
Cx does not automatically promote a named record tag to a bare type name; a type annotation must use `struct Name`, `union Name`, or `enum Name`, or an explicit `type` alias.

### 3. Track C-style tag and typedef namespaces separately

The parser should independently track:

- ordinary value identifiers;
- `struct`, `union`, and `enum` tags;
- typedef aliases introduced by `type`;
- labels;
- structure and union members;
- enumeration constants.

This preserves C behavior: `struct Point` is not interchangeable with a typedef named `Point`. Forward tags merge with later compatible definitions, while recursive record tags are available inside their own bodies.

### 4. Type-name lookup is semantic

The following positions need access to the scoped typedef environment:

- `sizeof(T)` versus `sizeof(expression)` (both parenthesized in Cx);
- `typeof(T)` versus `typeof(expression)` (both parenthesized in Cx);
- `_Generic` association types;
- type annotations;
- compound-literal type names;
- declaration parsing in `for` initializers.

This is the main place where a purely lexical PEG is insufficient. Because included headers are opaque, the Cx front end also needs a built-in or build-supplied C prelude containing the standard typedef names it must recognize, such as `size_t`, `ptrdiff_t`, `va_list`, and the character types. This is a semantic environment lookup, not preprocessor macro expansion.

### 5. Keep preprocessor directives opaque

Treat a `#` directive as trivia for the Cx grammar and preserve it verbatim in the output. The lexer performs line splicing first and emits each complete directive as one opaque token. Do not macro-expand replacement lists or parse directives such as `#define`, `#if`, or `#embed` into the Cx AST.

Included headers are external C and are never parsed as Cx declarations. A macro invocation in normal Cx code is just an ordinary call or identifier to the Cx parser; only the later C compiler sees its replacement list.

A `cinit` region may contain C preprocessor payload such as `#embed`, because that payload is deliberately opaque to the Cx parser. `cinit` itself is still Cx syntax and must be lowered to a C brace initializer. Line-oriented directives such as `#line` and `#embed` must be preserved without reflowing or rebasing. Raw `@identifier` escapes are handled only in ordinary Cx source, not inside macro replacement lists.

### 6. Use context-specific colon productions

The token `:` appears in:

```text
binding:         name : type
struct field:    name : type
bit-field:       name : type : width
unnamed bitfield: : width
record literal:  field : expression
generic assoc:   type : expression
enum underlying: enum Name : type
label:           identifier :
```

Trying to parse all of these with one generic colon rule will create ambiguity.

### 7. Keep required semicolons

Cx uses explicit semicolons after declarations and statements. The only intentional omission is the declaration inside a `for` initializer, where the header's first semicolon already terminates it.

### 8. Keep GNU syntax in a separate dialect

The following forms are not part of strict C23:

- K&R function definitions;
- statement expressions;
- computed `goto`;
- nested functions;
- case ranges;
- omitted-middle `?:`;
- zero-length arrays;
- empty structs;
- old field designators and range designators;
- casts to unions;
- `__int128`, vector attributes, and inline assembly;
- `__auto_type`, `__typeof__`, `__alignof__`, and `__extension__`;
- GNU preprocessor spellings such as `##__VA_ARGS__`, `__COUNTER__`, and `__PRETTY_FUNCTION__`;
- vendor builtins and vendor attributes.

They should be parsed only when a GNU or target-specific dialect is explicitly enabled.

## Recommended grammar shape

This is a structural sketch, not a complete grammar:

```text
translation-unit = { trivia | external-declaration }

trivia
    = whitespace
    | comment
    | directive-token

directive
    = directive-token

directive-token
    = one-opaque-logical-line-token

attributes
    = "[[" attribute ("," attribute)* ","? "]]"

raw-identifier
    = identifier
    | "@" identifier

record-field
    = raw-identifier

constant
    = integer-constant | floating-constant | character-constant | string-literal

attribute
    = raw-identifier ("(" balanced-tokens? ")")?

balanced-tokens
    = { balanced-token }

balanced-token
    = "(" balanced-tokens? ")"
    | "[" balanced-tokens? "]"
    | "{" balanced-tokens? "}"
    | any-token-except-balanced-delimiters

external-declaration
    = function-prototype
    | function-definition
    | binding-declaration
    | enum-declaration
    | record-declaration
    | type-alias
    | static-assert
    | attribute-only-declaration

function-prototype
    = attributes? function-specifiers?
      "function" raw-identifier "(" parameters? ")"
      ":" type attributes? ";"

parameters
    = parameter ("," parameter)* ","?

parameter-type-list
    = "void"
    | type ("," type)* ("," "...")?
    | "..."

function-specifiers
    = function-specifier*

function-specifier
    = "static" | "inline" | "_Noreturn"

attribute-only-declaration
    = attributes? ";"

static-assert
    = "static_assert" "(" constant-expression
      ("," string-literal)? ")" attributes? ";"

declaration-specifiers
    = declaration-specifier*

declaration-specifier
    = storage-class-specifier
    | alignment-specifier
    | attributes

storage-class-specifier
    = "static" | "extern" | "constexpr" | "thread_local" | "_Thread_local"

alignment-specifier
    = ("alignas" | "_Alignas") "(" (type | constant-expression) ")"

binding-declaration
    = attributes? declaration-specifiers?
      ("let" | "const") binding
      ("," binding)* ";"

binding
    = raw-identifier (":" type)? attributes? ("=" initializer)?

type-alias
    = "type" raw-identifier attributes? "=" (type | anonymous-record-type) attributes? ";"

enum-declaration
    = "enum" attributes? raw-identifier? attributes?
      (":" type)? enum-body? attributes? ";"

enum-body
    = "{" enumerator ("," enumerator)* ","? "}"

enumerator
    = raw-identifier attributes? ("=" constant-expression)?

constant-expression
    = conditional-expression

function-definition
    = attributes? function-specifiers?
      "function" raw-identifier "(" parameters? ")"
      ":" type attributes? compound-statement

parameter
    = raw-identifier ":" type
    | type
    | "..."

type
    = type-qualifier* atomic-specifier? type-base type-suffix*

type-base
    = built-in-type
    | tagged-type
    | raw-identifier
    | function-type
    | typeof-type
    | atomic-type
    | complex-type
    | paren-type

built-in-type
    = built-in-specifier+

built-in-specifier
    = "void" | "char" | "short" | "int" | "long" | "float"
    | "double" | "signed" | "unsigned" | "bool" | "char8_t"
    | "char16_t" | "char32_t" | "wchar_t" | "size_t" | "ptrdiff_t"
    | "nullptr_t" | "va_list" | "_BitInt" "(" constant-expression ")"
    | "_Decimal32" | "_Decimal64" | "_Decimal128"

function-type
    = "(" parameter-type-list? ")" "=>" type

paren-type
    = "(" type ")"

typeof-type
    = ("typeof" | "typeof_unqual" | "__typeof__") "(" (type | expression) ")"

tagged-type
    = ("struct" | "union" | "enum") raw-identifier

atomic-type
    = "_Atomic" "(" type ")"

complex-type
    = built-in-type ("_Complex" | "_Imaginary")

type-suffix
    = "*" (type-qualifier | "_Atomic")*
    | array-suffix

type-qualifier
    = "const" | "volatile" | "restrict"

atomic-specifier
    = "_Atomic"

array-suffix
    = "[" (type-qualifier | "_Atomic")* "static"?
      (type-qualifier | "_Atomic")* expression? "]"
    | "[" (type-qualifier | "_Atomic")* "*" "]"

initializer
    = expression
    | compound-literal
    | array-literal
    | record-literal
    | cinit-literal

array-literal
    = "[" initializer-list? "]"

initializer-list
    = initializer ("," initializer)* ","?

record-literal
    = "{" (record-field ":" initializer)
        ("," record-field ":" initializer)* ","? "}"
    | "{}"

cinit-literal
    = "cinit" "{" c-initializer-tokens "}"

c-initializer-tokens
    = { c-token | directive }

c-token
    = any-token-except-unmatched-brace

compound-literal
    = "(" (type | "static" type) ")" initializer

record-declaration
    = ("struct" | "union") attributes? raw-identifier?
      attributes? (record-body attributes? ";" | ";")

record-body
    = "{" record-member* "}"

named-field
    = attributes? raw-identifier ":" type attributes?
      (":" constant-expression)? ";"

unnamed-bit-field
    = ":" constant-expression ";"

record-member
    = named-field
    | unnamed-bit-field
    | record-declaration
    | static-assert

anonymous-record-type
    = ("struct" | "union") attributes? record-body

unary-expression
    = postfix-expression
    | "++" unary-expression
    | "--" unary-expression
    | unary-operator unary-expression
    | "sizeof" "(" (type | expression) ")"
    | "alignof" "(" type ")"
    | ("typeof" | "typeof_unqual") "(" (type | expression) ")"

unary-operator
    = "&" | "*" | "+" | "-" | "~" | "!"

postfix-expression
    = primary-expression postfix-operator*

postfix-operator
    = "[" expression "]"
    | "(" argument-expression-list? ")"
    | "." raw-identifier
    | "->" raw-identifier
    | "++" | "--"

primary-expression
    = raw-identifier
    | constant
    | string-literal
    | compound-literal
    | "(" expression ")"
    | generic-selection

generic-selection
    = "_Generic" "(" expression "," generic-association-list ")"

generic-association-list
    = generic-association ("," generic-association)*

generic-association
    = type ":" assignment-expression
    | "default" ":" assignment-expression

argument-expression-list
    = assignment-expression ("," assignment-expression)*

cast-expression
    = conversion-expression

conversion-expression
    = unary-expression ("as" type)*

multiplicative-expression
    = conversion-expression
    | multiplicative-expression ("*" | "/" | "%") conversion-expression

expression
    = assignment-expression ("," assignment-expression)*

assignment-expression
    = conditional-expression
    | unary-expression assignment-operator assignment-expression

assignment-operator
    = "=" | "*=" | "/=" | "%=" | "+=" | "-=" | "<<=" | ">>="
    | "&=" | "^=" | "|="

conditional-expression
    = logical-or-expression ("?" expression ":" conditional-expression)?

logical-or-expression
    = logical-and-expression ("||" logical-and-expression)*

logical-and-expression
    = inclusive-or-expression ("&&" inclusive-or-expression)*

inclusive-or-expression
    = exclusive-or-expression ("|" exclusive-or-expression)*

exclusive-or-expression
    = and-expression ("^" and-expression)*

and-expression
    = equality-expression ("&" equality-expression)*

equality-expression
    = relational-expression (("==" | "!=") relational-expression)*

relational-expression
    = shift-expression (("<" | ">" | "<=" | ">=") shift-expression)*

shift-expression
    = additive-expression (("<<" | ">>") additive-expression)*

additive-expression
    = multiplicative-expression (("+" | "-") multiplicative-expression)*

block-item
    = trivia
    | binding-declaration
    | record-declaration
    | enum-declaration
    | type-alias
    | static-assert
    | statement
    | label

compound-statement
    = "{" block-item* "}"

statement
    = attributes? (compound-statement
                  | selection-statement
                  | iteration-statement
                  | jump-statement
                  | expression-statement)

selection-statement
    = "if" "(" expression ")" statement ("else" statement)?
    | "switch" "(" expression ")" statement

iteration-statement
    = "while" "(" expression ")" statement
    | "do" statement "while" "(" expression ")" attributes? ";"
    | "for" "(" for-initializer? expression? ";" expression? ";" expression? ")" statement

for-initializer
    = ("let" | "const") binding ("," binding)*
    | expression

jump-statement
    = "goto" raw-identifier attributes? ";"
    | "continue" attributes? ";"
    | "break" attributes? ";"
    | "return" expression? attributes? ";"

expression-statement
    = attributes? expression? ";"

label
    = attributes? (raw-identifier | "case" constant-expression | "default") ":"
```

Named `struct`, `union`, and `enum` declarations must register their tag names before parsing fields so recursive types work. They remain tag names, not bare Cx type aliases. Anonymous struct/union members require a separate field-promotion pass before record literals are lowered. `cinit` is parsed as an opaque, balanced C-initializer region; any preprocessor directives inside it are preserved but not interpreted by the Cx parser. GNU-only designators inside `cinit` are therefore a dialect concern for the C toolchain, not Cx grammar sugar.

The actual implementation still needs the full C expression precedence chain, C declarator semantics, parameter adjustments, constant-expression validation, and attribute balancing.

## Example files

The repository contains side-by-side implementations:

- [`programs/01_hello_args.c`](programs/01_hello_args.c) and [`programs/01_hello_args.cx`](programs/01_hello_args.cx)
- [`programs/02_numbers_control.c`](programs/02_numbers_control.c) and [`programs/02_numbers_control.cx`](programs/02_numbers_control.cx)
- [`programs/03_arrays_strings_memory.c`](programs/03_arrays_strings_memory.c) and [`programs/03_arrays_strings_memory.cx`](programs/03_arrays_strings_memory.cx)
- [`programs/04_records_callbacks.c`](programs/04_records_callbacks.c) and [`programs/04_records_callbacks.cx`](programs/04_records_callbacks.cx)
- [`programs/05_declarations_preprocessor.c`](programs/05_declarations_preprocessor.c) and [`programs/05_declarations_preprocessor.cx`](programs/05_declarations_preprocessor.cx)
- [`programs/06_syntax_reference.c`](programs/06_syntax_reference.c) and [`programs/06_syntax_reference.cx`](programs/06_syntax_reference.cx) for C23
- [`programs/07_gnu_extensions.c`](programs/07_gnu_extensions.c) and [`programs/07_gnu_extensions.cx`](programs/07_gnu_extensions.cx) for common GCC and K&R extensions
