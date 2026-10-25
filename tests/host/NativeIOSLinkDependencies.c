#include <stddef.h>

extern int setupterm(const char *, int, int *);
extern void *xmlReadMemory(const char *, int, const char *, const char *, int);

static int (*volatile terminfo_symbol)(const char *, int, int *) = setupterm;
static void *(*volatile xml_symbol)(const char *, int, const char *, const char *, int) = xmlReadMemory;

int main(void) {
    return terminfo_symbol == NULL || xml_symbol == NULL;
}
