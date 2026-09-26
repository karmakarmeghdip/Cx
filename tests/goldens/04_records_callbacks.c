#include <stdio.h>

#include <stdlib.h>

enum color {
    COLOR_RED,
    COLOR_GREEN,
    COLOR_BLUE,
};

struct point {
    int x;
    int y;
};

union scalar {
    int integer;
    float real;
};

struct node {
    int value;
    struct node *next;
};

typedef struct node Node;

typedef struct point Point;

typedef union scalar Scalar;

typedef int (*binary_operation)(int, int);

static int add(int left, int right)
{
    return left + right;
}

static int multiply(int left, int right)
{
    return left * right;
}

static int apply(int left, int right, binary_operation operation)
{
    return operation(left, right);
}

static int squared_distance(Point point)
{
    return point.x * point.x + point.y * point.y;
}

static void translate(Point *point, int dx, int dy)
{
    point->x += dx;
    point->y += dy;
}

int main(void)
{
    Point point = {.x = 3, .y = 4};
    Point copy = (Point){.x = -2, .y = 7};
    Scalar value = {.real = 1.5f};
    Node tail = {.value = 2, .next = NULL};
    Node head = {.value = 1, .next = &tail};
    binary_operation operation = point.x > copy.x ? add : multiply;
    translate(&point, 2, -1);
    printf("point: (%d, %d), distance²=%d\n", point.x, point.y, squared_distance(point));
    printf("copy: (%d, %d), operation=%d\n", copy.x, copy.y, apply(6, 7, operation));
    printf("union: %.1f\n", value.real);
    printf("list: %d -> %d\n", head.value, head.next->value);
    switch ((enum color)point.x) {
        case COLOR_RED:
        puts("red");
        break;
        case COLOR_GREEN:
        puts("green");
        break;
        case COLOR_BLUE:
        puts("blue");
        break;
    }
    return 0;
}
