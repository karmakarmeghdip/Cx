#include <stddef.h>

#include <stdio.h>

#include <stdlib.h>

#include <string.h>

static int sum(size_t count, const int *values)
{
    int total = 0;
    for (size_t index = 0; index < count; ++index) {
        total += values[index];
    }
    return total;
}

static void reverse(int *values, size_t count)
{
    if (count < 2) {
        return;
    }
    for (size_t left = 0, right = count - 1; left < right; ++left, --right) {
        int temporary = values[left];
        values[left] = values[right];
        values[right] = temporary;
    }
}

static void fill_row(int row[restrict static 3], int start)
{
    for (size_t index = 0; index < 3; ++index) {
        row[index] = start + (int)index;
    }
}

int main(void)
{
    int vector[5] = {5, 1, 4, 2, 3};
    int inferred[] = {9, 8, 7};
    int matrix[2][3] = {{1, 2, 3}, {4, 5, 6}};
    size_t variable_size = 4;
    int variable_length[variable_size];
    char text[] = "variably modified";
    char copy[sizeof(text)];
    for (size_t index = 0; index < variable_size; ++index) {
        variable_length[index] = (int)index * index;
    }
    memcpy(copy, text, sizeof(text));
    int before = sum(sizeof(vector) / sizeof(vector[0]), vector);
    reverse(vector, sizeof(vector) / sizeof(vector[0]));
    int after = sum(sizeof(vector) / sizeof(vector[0]), vector);
    fill_row(matrix[1], 10);
    int *heap = calloc(6, sizeof(*heap));
    if (heap == NULL) {
        return 1;
    }
    for (size_t index = 0; index < 6; ++index) {
        heap[index] = 6 - (int)index;
    }
    int *grown = realloc(heap, 8 * sizeof(*heap));
    if (grown == NULL) {
        free(heap);
        return 1;
    }
    heap = grown;
    heap[6] = 0;
    heap[7] = 7;
    int *last = heap + 7;
    ptrdiff_t distance = last - heap;
    printf("vector: %d -> %d\n", before, after);
    printf("inferred: %d %d %d\n", inferred[0], inferred[1], inferred[2]);
    printf("matrix: %d %d %d\n", matrix[0][0], matrix[1][0], matrix[1][2]);
    printf("vla: %zu %zu %d\n", sizeof(variable_length), sizeof(variable_length) / sizeof(variable_length[0]), variable_length[3]);
    printf("text: %s / %s\n", text, copy);
    printf("heap: %d %d distance=%td\n", heap[0], *last, distance);
    free(heap);
    return 0;
}
