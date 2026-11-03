/*
 * bridgeplay-epic-trampoline.c
 * Universal Mach-O in-directory launcher trampoline for Epic Games Store.
 *
 * Placed inside the game's InstallLocation as "bridgeplay-epic-trampoline".
 * Bypasses Unreal Engine's FLocalAppManifest path sanitizer trap, forwards
 * Epic OAuth exchange tokens, injects -nobattleye for Story Mode, resolves
 * the active Bridgeplay runner, sets STEAM_COMPAT_DATA_PATH, and maintains
 * the multi-launcher process supervision barrier.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <limits.h>
#include <dirent.h>
#include <mach-o/dyld.h>

#define MAX_ARGS 1024

static pid_t g_child_pid = -1;
static pid_t g_ws_pid = -1;

static void forward_signal(int sig)
{
    if (g_child_pid > 0) {
        kill(g_child_pid, sig);
    }
    if (g_ws_pid > 0) {
        kill(g_ws_pid, sig);
    }
}

static void setup_signals(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = forward_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;

    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);
}

static void ensure_directory(const char *path)
{
    if (!path || !path[0]) return;
    char tmp[PATH_MAX];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp), "%s", path);
    len = strlen(tmp);
    if (len == 0) return;
    if (tmp[len - 1] == '/') {
        tmp[len - 1] = 0;
    }
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

static int file_is_executable(const char *path)
{
    struct stat st;
    return (stat(path, &st) == 0 && (st.st_mode & S_IXUSR));
}

/* Locate the active Bridgeplay/Proton runner script */
static int resolve_runner_script(const char *home, char *out_path, size_t out_size)
{
    /* 1. Explicit environment override */
    const char *env_runner = getenv("BRIDGEPLAY_RUNNER_PATH");
    if (env_runner && file_is_executable(env_runner)) {
        snprintf(out_path, out_size, "%s", env_runner);
        return 1;
    }

    /* 2. Standalone Bridgeplay runner in Application Support */
    snprintf(out_path, out_size, "%s/Library/Application Support/bridgeplay/compat-tool/run", home);
    if (file_is_executable(out_path)) return 1;

    snprintf(out_path, out_size, "%s/Library/Application Support/bridgeplay/compat_run.sh", home);
    if (file_is_executable(out_path)) return 1;

    /* 3. Preferred hero: bridgeplay-proton-winecx-11.17 in compatibilitytools.d */
    snprintf(out_path, out_size,
             "%s/Library/Application Support/Steam/compatibilitytools.d/bridgeplay-proton-winecx-11.17/run", home);
    if (file_is_executable(out_path)) return 1;

    /* 4. Preferred hero: bridgeplay-proton-mach9 */
    snprintf(out_path, out_size,
             "%s/Library/Application Support/Steam/compatibilitytools.d/bridgeplay-proton-mach9/run", home);
    if (file_is_executable(out_path)) return 1;

    /* 5. Scan compatibilitytools.d for any bridgeplay-proton-* or notproton-* tool */
    char tools_dir[PATH_MAX];
    snprintf(tools_dir, sizeof(tools_dir),
             "%s/Library/Application Support/Steam/compatibilitytools.d", home);
    DIR *d = opendir(tools_dir);
    if (d) {
        struct dirent *dir;
        while ((dir = readdir(d)) != NULL) {
            if (strncmp(dir->d_name, "bridgeplay-proton-", 18) == 0 ||
                strncmp(dir->d_name, "notproton-", 10) == 0) {
                snprintf(out_path, out_size, "%s/%s/run", tools_dir, dir->d_name);
                if (file_is_executable(out_path)) {
                    closedir(d);
                    return 1;
                }
            }
        }
        closedir(d);
    }

    /* 6. Legacy fallback */
    snprintf(out_path, out_size, "%s/Library/Application Support/notproton/compat_run.sh", home);
    if (file_is_executable(out_path)) return 1;

    return 0;
}

/* Locate active wineserver executable dynamically across installed runners */
static int resolve_wineserver(const char *home, char *out_path, size_t out_size)
{
    const char *env_ws = getenv("WINESERVER");
    if (env_ws && file_is_executable(env_ws)) {
        snprintf(out_path, out_size, "%s", env_ws);
        return 1;
    }

    /* Primary runner paths */
    const char *candidates[] = {
        "crossover-winecx-11.17",
        "crossover-mach9-0.1.0",
        "crossover-26.3.0.39832",
        "crossover-winehq-11.15",
        NULL
    };

    for (int i = 0; candidates[i]; i++) {
        snprintf(out_path, out_size,
                 "%s/Library/Application Support/bridgeplay/runners/%s/CrossOver/bin/wineserver-arm64",
                 home, candidates[i]);
        if (file_is_executable(out_path)) return 1;

        snprintf(out_path, out_size,
                 "%s/Library/Application Support/bridgeplay/runners/%s/CrossOver/bin/wineserver",
                 home, candidates[i]);
        if (file_is_executable(out_path)) return 1;
    }

    /* Dynamic scan across all installed runner folders */
    char runners_dir[PATH_MAX];
    snprintf(runners_dir, sizeof(runners_dir),
             "%s/Library/Application Support/bridgeplay/runners", home);
    DIR *d = opendir(runners_dir);
    if (d) {
        struct dirent *dir;
        while ((dir = readdir(d)) != NULL) {
            if (dir->d_name[0] == '.') continue;
            snprintf(out_path, out_size, "%s/%s/CrossOver/bin/wineserver-arm64", runners_dir, dir->d_name);
            if (file_is_executable(out_path)) {
                closedir(d);
                return 1;
            }
            snprintf(out_path, out_size, "%s/%s/CrossOver/bin/wineserver", runners_dir, dir->d_name);
            if (file_is_executable(out_path)) {
                closedir(d);
                return 1;
            }
        }
        closedir(d);
    }

    return 0;
}

int main(int argc, char *argv[])
{
    char self_path[PATH_MAX];
    uint32_t self_len = sizeof(self_path);
    if (_NSGetExecutablePath(self_path, &self_len) != 0) {
        fprintf(stderr, "[bridgeplay-epic] Error: Unable to determine executable path\n");
        return 1;
    }

    /* Resolve canonical path of game install location */
    char real_self_path[PATH_MAX];
    if (!realpath(self_path, real_self_path)) {
        strncpy(real_self_path, self_path, PATH_MAX - 1);
        real_self_path[PATH_MAX - 1] = '\0';
    }

    char *last_slash = strrchr(real_self_path, '/');
    char install_dir[PATH_MAX];
    if (last_slash) {
        size_t len = (size_t)(last_slash - real_self_path);
        strncpy(install_dir, real_self_path, len);
        install_dir[len] = '\0';
    } else {
        strcpy(install_dir, ".");
    }

    /* Locate Bridgeplay support directory and runner */
    const char *home = getenv("HOME");
    if (!home) {
        fprintf(stderr, "[bridgeplay-epic] Error: HOME environment variable not set\n");
        return 1;
    }

    char runner_path[PATH_MAX];
    if (!resolve_runner_script(home, runner_path, sizeof(runner_path))) {
        fprintf(stderr, "[bridgeplay-epic] Error: Could not locate a valid Bridgeplay runner script (run / compat_run.sh)\n");
        return 1;
    }

    /* Determine Target Windows Executable */
    char target_exe[PATH_MAX];
    int arg_start = 1;
    const char *custom_exe = getenv("BRIDGEPLAY_CUSTOM_EXE");

    if (argc > 1 && strlen(argv[1]) >= 4 && strcasecmp(argv[1] + strlen(argv[1]) - 4, ".exe") == 0) {
        snprintf(target_exe, sizeof(target_exe), "%s", argv[1]);
        arg_start = 2;
        /* Re-derive install_dir from target_exe */
        char *target_slash = strrchr(target_exe, '/');
        if (target_slash) {
            size_t tlen = (size_t)(target_slash - target_exe);
            strncpy(install_dir, target_exe, tlen);
            install_dir[tlen] = '\0';
        }
    } else if (custom_exe && custom_exe[0] != '\0') {
        if (custom_exe[0] == '/') {
            snprintf(target_exe, sizeof(target_exe), "%s", custom_exe);
        } else {
            snprintf(target_exe, sizeof(target_exe), "%s/%s", install_dir, custom_exe);
        }
    } else {
        /* Check if bridgeplay-target.txt exists inside game install directory */
        char target_file[PATH_MAX];
        snprintf(target_file, sizeof(target_file), "%s/bridgeplay-target.txt", install_dir);
        FILE *tf = fopen(target_file, "r");
        char saved_name[PATH_MAX] = {0};
        if (tf) {
            if (fgets(saved_name, sizeof(saved_name), tf)) {
                size_t nl = strcspn(saved_name, "\r\n");
                saved_name[nl] = '\0';
            }
            fclose(tf);
        }

        if (saved_name[0] != '\0') {
            if (saved_name[0] == '/') {
                snprintf(target_exe, sizeof(target_exe), "%s", saved_name);
            } else {
                snprintf(target_exe, sizeof(target_exe), "%s/%s", install_dir, saved_name);
            }
        } else {
            /* Default hero target */
            snprintf(target_exe, sizeof(target_exe), "%s/PlayGTAV.exe", install_dir);
        }
    }

    /* Prepare argument vectors */
    char *new_argv[MAX_ARGS];
    int new_argc = 0;

    new_argv[new_argc++] = runner_path;
    new_argv[new_argc++] = "waitforexitandrun";
    new_argv[new_argc++] = target_exe;

    int has_nobattleye = 0;
    int has_epicapp = 0;
    char epic_app_id[PATH_MAX] = {0};

    /* Forward incoming Epic arguments (-AUTH_PASSWORD, -epicapp, etc.) */
    for (int i = arg_start; i < argc && new_argc < (MAX_ARGS - 8); i++) {
        if (strcmp(argv[i], "-nobattleye") == 0) {
            has_nobattleye = 1;
        }
        if (strncmp(argv[i], "-epicapp=", 9) == 0) {
            has_epicapp = 1;
            strncpy(epic_app_id, argv[i] + 9, sizeof(epic_app_id) - 1);
        }
        new_argv[new_argc++] = argv[i];
    }

    /* Automatically inject -nobattleye to bypass kernel anti-cheat deadlock */
    if (!has_nobattleye && new_argc < (MAX_ARGS - 1)) {
        new_argv[new_argc++] = "-nobattleye";
    }

    new_argv[new_argc] = NULL;

    /* Export store environment variables */
    setenv("BRIDGEPLAY_STORE", "epic", 1);
    if (!has_epicapp || epic_app_id[0] == '\0') {
        strncpy(epic_app_id, "0584d2013f0149a791e7b9bad0eec102", sizeof(epic_app_id) - 1);
    }
    setenv("BRIDGEPLAY_GAME_ID", epic_app_id, 1);
    setenv("STEAM_COMPAT_INSTALL_PATH", install_dir, 1);
    setenv("STEAM_COMPAT_CLIENT_INSTALL_PATH", "/Applications/Epic Games Launcher.app", 0);

    /* Construct and export STEAM_COMPAT_DATA_PATH (Prefix Directory) */
    char compat_data_path[PATH_MAX];
    if (strcmp(epic_app_id, "0584d2013f0149a791e7b9bad0eec102") == 0 ||
        strcmp(epic_app_id, "9a5f2780e5b741dc94f4bf6d07e6012a") == 0 ||
        strcasecmp(epic_app_id, "GrandTheftAutoV") == 0 ||
        strcasecmp(epic_app_id, "GrandTheftAutoVEnhanced") == 0) {
        /* Shared Rockstar prefix so Social Club credentials and offline tickets persist */
        snprintf(compat_data_path, sizeof(compat_data_path),
                 "%s/Library/Application Support/bridgeplay/prefixes/epic-rockstar-gtav", home);
    } else {
        snprintf(compat_data_path, sizeof(compat_data_path),
                 "%s/Library/Application Support/bridgeplay/prefixes/epic-%s", home, epic_app_id);
    }
    ensure_directory(compat_data_path);
    setenv("STEAM_COMPAT_DATA_PATH", compat_data_path, 1);

    setup_signals();

    /* Spawn runner script */
    g_child_pid = fork();
    if (g_child_pid < 0) {
        perror("[bridgeplay-epic] fork failed");
        return 1;
    }

    if (g_child_pid == 0) {
        /* Child process */
        chdir(install_dir);
        execv(runner_path, new_argv);
        perror("[bridgeplay-epic] execv failed");
        _exit(127);
    }

    /* Parent process: Wait barrier for child process */
    int status = 0;
    while (waitpid(g_child_pid, &status, 0) < 0) {
        if (errno == EINTR) {
            continue;
        }
        perror("[bridgeplay-epic] waitpid failed");
        return 1;
    }
    g_child_pid = -1;

    /* Secondary wineserver supervision fallback:
     * If the runner exited but detached Wine child processes remain attached in the prefix,
     * block until all Windows processes terminate to avoid premature Epic Cloud Save sync.
     */
    char wineserver_bin[PATH_MAX];
    if (resolve_wineserver(home, wineserver_bin, sizeof(wineserver_bin))) {
        char prefix_dir[PATH_MAX];
        snprintf(prefix_dir, sizeof(prefix_dir), "%s/pfx", compat_data_path);
        setenv("WINEPREFIX", prefix_dir, 1);

        g_ws_pid = fork();
        if (g_ws_pid == 0) {
            execl(wineserver_bin, "wineserver", "-w", (char *)NULL);
            _exit(0);
        } else if (g_ws_pid > 0) {
            waitpid(g_ws_pid, NULL, 0);
            g_ws_pid = -1;
        }
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }

    return 0;
}
