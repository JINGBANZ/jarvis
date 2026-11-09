#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (getsid(0) != getpid() && setsid() == -1) return 2;
    signal(SIGTERM, SIG_IGN);
    char temporary[strlen(argv[1]) + sizeof(".XXXXXX")];
    snprintf(temporary, sizeof(temporary), "%s.XXXXXX", argv[1]);
    int descriptor = mkstemp(temporary);
    if (descriptor == -1) return 3;
    FILE *marker = fdopen(descriptor, "w");
    if (!marker) {
        close(descriptor);
        unlink(temporary);
        return 3;
    }
    int written = fprintf(marker, "%d", getpid());
    int closed = fclose(marker);
    if (written < 0 || closed != 0 || rename(temporary, argv[1]) != 0) {
        unlink(temporary);
        return 3;
    }
    for (;;) pause();
}
