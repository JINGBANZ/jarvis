#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (getsid(0) != getpid() && setsid() == -1) return 2;
    signal(SIGTERM, SIG_IGN);
    FILE *marker = fopen(argv[1], "w");
    if (!marker) return 3;
    fprintf(marker, "%d", getpid());
    fclose(marker);
    for (;;) pause();
}
