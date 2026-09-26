typedef struct {
    int len;
    int *items;
} Vec;

const int MOD = 1000;

int vec_sum(Vec *v)
{
    int total = 0;
    for (int i = 0; i < v->len; ++i) {
        total += v->items[i];
    }
    return total;
}

void vec_scale(Vec *v, int factor)
{
    for (int i = 0; i < v->len; ++i) {
        v->items[i] = (v->items[i] * factor) % MOD;
    }
}
