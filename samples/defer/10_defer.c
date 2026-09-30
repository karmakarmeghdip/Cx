#include <stdio.h>

static void test_lifo(void)
{
    printf("--- LIFO Order Test ---\n");
    printf("inside body\n");
    printf("3 (declared third, runs first)\n");
    printf("2 (declared second, runs second)\n");
    printf("1 (declared first, runs last)\n");
}

static int test_early_return(int flag)
{
    int x = 100;
    if (flag > 0) {
        {
            int __cx_ret_1 = x + 5;
            printf("cleanup: inner branch\n");
            printf("cleanup: restoring state\n");
            return __cx_ret_1;
        }
    }
    {
        int __cx_ret_2 = 0;
        printf("cleanup: restoring state\n");
        return __cx_ret_2;
    }
}

static void test_loop(void)
{
    printf("--- Loop Scope Test ---\n");
    for (int i = 0; i < 4; i = i + 1) {
        if (i == 1) {
            printf("continue at %d\n", i);
            {
                printf("defer loop iteration %d\n", i);
                continue;
            }
        }
        if (i == 2) {
            printf("break at %d\n", i);
            {
                printf("defer loop iteration %d\n", i);
                break;
            }
        }
        printf("step %d\n", i);
        printf("defer loop iteration %d\n", i);
    }
}

static void test_compound(void)
{
    printf("--- Compound Defer Test ---\n");
    int a = 10;
    int b = 20;
    printf("work done: a=%d b=%d\n", a, b);
    {
        a = a + 5;
        b = b * 2;
        printf("compound deferred cleanup: a=%d b=%d\n", a, b);
    }
}

int main(void)
{
    test_lifo();
    printf("--- Early Return Test ---\n");
    int val = test_early_return(1);
    printf("returned value = %d\n", val);
    test_loop();
    test_compound();
    printf("--- Done ---\n");
    return 0;
}
