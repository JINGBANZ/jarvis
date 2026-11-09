#include "JarvisTestHost.h"
#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

void jarvis_test_host_link(void) {}

// Darwin's SwiftPM helper loads the test bundle before discovery. Register that
// host at load time because it can run outside the swift-package process group.
__attribute__((constructor)) static void register_test_host(void) {
    char *python = getenv("JARVIS_TEST_PYTHON");
    char *script = getenv("JARVIS_TEST_SUPERVISOR");
    char *socket = getenv("JARVIS_TEST_RUN_SOCKET");
    char *token = getenv("JARVIS_TEST_RUN_TOKEN");
    if (!python || python[0] != '/' || !script || script[0] != '/' ||
        !socket || socket[0] != '/' || !token || !token[0]) {
        fputs("Test host requires an admitted repository test command.\n", stderr);
        _exit(70);
    }
    char *arguments[] = {python, "-I", script, "register-test-host", NULL};
    pid_t reporter;
    int status;
    if (posix_spawn(&reporter, python, NULL, NULL, arguments, environ) != 0) {
        fputs("Test host could not start its ownership reporter.\n", stderr);
        _exit(70);
    }
    pid_t waited;
    do { waited = waitpid(reporter, &status, 0); } while (waited < 0 && errno == EINTR);
    if (waited != reporter || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fputs("Test host ownership registration failed; refusing to run tests.\n", stderr);
        _exit(70);
    }
}
