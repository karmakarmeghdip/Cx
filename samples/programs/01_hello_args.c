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
