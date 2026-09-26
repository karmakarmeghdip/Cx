#include <stdio.h>

/* Hand-maintained prototypes: the "dumb header" that
 * `import { Vec, vec_sum, vec_scale, MOD }` replaces. */

typedef struct {
    int len;
    int *items;
} Vec;

int vec_sum(Vec *v);
void vec_scale(Vec *v, int factor);
extern const int MOD;

int main(void)
{
    int values[4] = {3, 1, 4, 1};
    Vec v = {.len = 4, .items = values};
    printf("sum=%d mod=%d\n", vec_sum(&v), MOD);
    vec_scale(&v, 10);
    printf("sum=%d\n", vec_sum(&v));
    return 0;
}
