#include <stdio.h>
#include <unistd.h>

int main(void) {
    char host[256] = {0};
    gethostname(host, sizeof(host) - 1);
    printf("Hello from hello-world on %s (ADSP-SC598)\n", host);
    return 0;
}
