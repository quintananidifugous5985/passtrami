#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char error_event[] =
    "{\"type\":\"state\",\"state\":\"error\",\"message\":\"Full Disk Access is required for iPhone approval.\"}\n";

int main(int argc, char **argv) {
    const char *resources = NULL;
    for (int i = 1; i + 1 < argc; ++i) {
        if (strcmp(argv[i], "--resources") == 0) resources = argv[i + 1];
    }
    if (!resources) return 64;
    char path[4096], scenario[64] = {0};
    snprintf(path, sizeof(path), "%s/scenario", resources);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 65;
    ssize_t count = read(fd, scenario, sizeof(scenario) - 1);
    close(fd);
    if (count <= 0) return 65;
    if (strcmp(scenario, "empty") == 0) return 1;
    if (strcmp(scenario, "fragmented") == 0) {
        size_t split = strlen(error_event) / 2;
        write(STDOUT_FILENO, error_event, split);
        usleep(20000);
        write(STDOUT_FILENO, error_event + split, strlen(error_event) - split);
        return 1;
    }
    write(STDOUT_FILENO, error_event, strlen(error_event));
    if (strcmp(scenario, "unspecified") == 0) {
        const char unspecified[] = "{\"type\":\"state\",\"state\":\"error\"}\n";
        write(STDOUT_FILENO, unspecified, strlen(unspecified));
    }
    if (strcmp(scenario, "recovered") == 0) {
        const char locked[] = "{\"type\":\"state\",\"state\":\"locked\"}\n";
        write(STDOUT_FILENO, locked, strlen(locked));
    }
    if (strcmp(scenario, "inherited") == 0) {
        pid_t child = fork();
        if (child < 0) return 66;
        if (child == 0) {
            // The test kills this child after checking that engine exit is delivered.
            sleep(15);
            _exit(0);
        }
        snprintf(path, sizeof(path), "%s/held-writer-pid", resources);
        FILE *file = fopen(path, "w");
        if (!file) { kill(child, SIGKILL); return 67; }
        fprintf(file, "%d", child);
        fclose(file);
    }
    return 1;
}
