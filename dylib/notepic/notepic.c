/*
 * notepic.c
 * Bridgeplay runtime hook for Epic Games Launcher (eglv2) on macOS.
 *
 * Hooks platform resolution in eglv2_lib to present Windows game compatibility,
 * routes manifest downloads for Windows depots, intercepts game launches via
 * posix_spawn/posix_spawnp, and forwards execution to bridgeplay-epic-trampoline.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define NOTEPIC_LOG(fmt, ...) \
    fprintf(stderr, "[notepic] " fmt "\n", ##__VA_ARGS__)

extern int DobbyHook(void *address, void *replace_call, void **origin_call);

struct RustStr {
    const char *ptr;
    uint64_t len;
};

struct RustSlice {
    const struct RustStr *ptr;
    uint64_t len;
};

static const struct RustStr s_windows_str = { "Windows", 7 };
static const struct RustStr s_platform_candidates[2] = {
    { "Windows", 7 },
    { "Mac", 3 }
};

static struct RustStr np_hook_preferred_build_platform(void) {
    return s_windows_str;
}

static struct RustSlice np_hook_build_platform_candidates(void) {
    struct RustSlice s;
    s.ptr = s_platform_candidates;
    s.len = 2;
    return s;
}

static int (*orig_posix_spawn)(pid_t *restrict pid, const char *restrict path,
                               const posix_spawn_file_actions_t *file_actions,
                               const posix_spawnattr_t *restrict attrp,
                               char *const argv[restrict],
                               char *const envp[restrict]) = NULL;

static int (*orig_posix_spawnp)(pid_t *restrict pid, const char *restrict file,
                                const posix_spawn_file_actions_t *file_actions,
                                const posix_spawnattr_t *restrict attrp,
                                char *const argv[restrict],
                                char *const envp[restrict]) = NULL;

static int is_exe(const char *path) {
    if (!path) return 0;
    size_t len = strlen(path);
    if (len < 4) return 0;
    return (strcasecmp(path + len - 4, ".exe") == 0);
}

static const char *resolve_trampoline(void) {
    static char s_trampoline_path[PATH_MAX] = {0};
    if (s_trampoline_path[0]) return s_trampoline_path;

    const char *env_trampoline = getenv("BRIDGEPLAY_EPIC_TRAMPOLINE");
    if (env_trampoline && access(env_trampoline, X_OK) == 0) {
        snprintf(s_trampoline_path, sizeof(s_trampoline_path), "%s", env_trampoline);
        return s_trampoline_path;
    }

    const char *home = getenv("HOME");
    if (home) {
        snprintf(s_trampoline_path, sizeof(s_trampoline_path),
                 "%s/Library/Application Support/bridgeplay/bin/bridgeplay-epic-trampoline", home);
        if (access(s_trampoline_path, X_OK) == 0) return s_trampoline_path;

        snprintf(s_trampoline_path, sizeof(s_trampoline_path),
                 "%s/Library/Application Support/bridgeplay/bridgeplay-epic-trampoline", home);
        if (access(s_trampoline_path, X_OK) == 0) return s_trampoline_path;
    }

    const char *bundle_path = "/Applications/Bridgeplay.app/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload/bridgeplay-epic-trampoline";
    if (access(bundle_path, X_OK) == 0) {
        snprintf(s_trampoline_path, sizeof(s_trampoline_path), "%s", bundle_path);
        return s_trampoline_path;
    }

    const char *app_path = "/Applications/Bridgeplay.app/Contents/Resources/payload/bridgeplay-epic-trampoline";
    if (access(app_path, X_OK) == 0) {
        snprintf(s_trampoline_path, sizeof(s_trampoline_path), "%s", app_path);
        return s_trampoline_path;
    }

    return NULL;
}

static int hook_posix_spawn(pid_t *restrict pid, const char *restrict path,
                            const posix_spawn_file_actions_t *file_actions,
                            const posix_spawnattr_t *restrict attrp,
                            char *const argv[restrict],
                            char *const envp[restrict]) {
    if (is_exe(path)) {
        NOTEPIC_LOG("Intercepted Windows game posix_spawn: %s", path);
        const char *tramp = resolve_trampoline();
        if (tramp) {
            NOTEPIC_LOG("Redirecting to Bridgeplay trampoline: %s", tramp);
            int count = 0;
            while (argv && argv[count]) count++;
            char **new_argv = (char **)malloc((count + 3) * sizeof(char *));
            if (new_argv) {
                new_argv[0] = (char *)tramp;
                new_argv[1] = (char *)path;
                for (int i = 1; i < count; i++) {
                    new_argv[i + 1] = argv[i];
                }
                new_argv[count + 1] = NULL;

                int rc = orig_posix_spawn(pid, tramp, file_actions, attrp, new_argv, envp);
                free(new_argv);
                return rc;
            }
        } else {
            NOTEPIC_LOG("Warning: bridgeplay-epic-trampoline not found!");
        }
    }
    return orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

static int hook_posix_spawnp(pid_t *restrict pid, const char *restrict file,
                             const posix_spawn_file_actions_t *file_actions,
                             const posix_spawnattr_t *restrict attrp,
                             char *const argv[restrict],
                             char *const envp[restrict]) {
    if (is_exe(file)) {
        NOTEPIC_LOG("Intercepted Windows game posix_spawnp: %s", file);
        const char *tramp = resolve_trampoline();
        if (tramp) {
            NOTEPIC_LOG("Redirecting to Bridgeplay trampoline: %s", tramp);
            int count = 0;
            while (argv && argv[count]) count++;
            char **new_argv = (char **)malloc((count + 3) * sizeof(char *));
            if (new_argv) {
                new_argv[0] = (char *)tramp;
                new_argv[1] = (char *)file;
                for (int i = 1; i < count; i++) {
                    new_argv[i + 1] = argv[i];
                }
                new_argv[count + 1] = NULL;

                int rc = orig_posix_spawnp(pid, tramp, file_actions, attrp, new_argv, envp);
                free(new_argv);
                return rc;
            }
        } else {
            NOTEPIC_LOG("Warning: bridgeplay-epic-trampoline not found!");
        }
    }
    return orig_posix_spawnp(pid, file, file_actions, attrp, argv, envp);
}

static void clear_stale_availability_cache(void) {
    const char *home = getenv("HOME");
    if (!home) return;

    char base_dir[PATH_MAX];
    snprintf(base_dir, sizeof(base_dir),
             "%s/Library/Application Support/com.epicgames.eglv2/cache/prod/account", home);

    DIR *d = opendir(base_dir);
    if (!d) return;

    struct dirent *dir;
    while ((dir = readdir(d)) != NULL) {
        if (dir->d_name[0] == '.') continue;
        char file_path[PATH_MAX];
        snprintf(file_path, sizeof(file_path), "%s/%s/platform-availability-cache.json",
                 base_dir, dir->d_name);
        FILE *f = fopen(file_path, "r");
        if (f) {
            char buf[512] = {0};
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            if (n > 0 && strstr(buf, "\"platform\":\"Mac\"")) {
                NOTEPIC_LOG("Clearing stale Mac platform-availability cache: %s", file_path);
                unlink(file_path);
            }
        }
    }
    closedir(d);
}

static void scan_and_hook_symbols(void) {
    /* Locate main MH_EXECUTE executable image */
    uint32_t image_count = _dyld_image_count();
    uint32_t main_idx = UINT32_MAX;

    for (uint32_t i = 0; i < image_count; i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            main_idx = i;
            break;
        }
    }

    if (main_idx == UINT32_MAX) {
        NOTEPIC_LOG("Error: Could not locate main MH_EXECUTE image");
        return;
    }

    const char *img_path = _dyld_get_image_name(main_idx);
    intptr_t slide = _dyld_get_image_vmaddr_slide(main_idx);
    NOTEPIC_LOG("Scanning main binary: %s (slide=0x%lx)", img_path, slide);

    FILE *f = fopen(img_path, "rb");
    if (!f) {
        NOTEPIC_LOG("Error: Cannot open main executable on disk");
        return;
    }

    struct mach_header_64 header;
    if (fread(&header, sizeof(header), 1, f) != 1 || header.magic != MH_MAGIC_64) {
        fclose(f);
        NOTEPIC_LOG("Error: Invalid 64-bit Mach-O header");
        return;
    }

    struct symtab_command symtab = {0};
    int found_symtab = 0;

    for (uint32_t i = 0; i < header.ncmds; i++) {
        struct load_command lc;
        long cmd_start = ftell(f);
        if (fread(&lc, sizeof(lc), 1, f) != 1) break;

        if (lc.cmd == LC_SYMTAB) {
            fseek(f, cmd_start, SEEK_SET);
            if (fread(&symtab, sizeof(symtab), 1, f) == 1) {
                found_symtab = 1;
            }
            break;
        }
        fseek(f, cmd_start + lc.cmdsize, SEEK_SET);
    }

    if (!found_symtab || symtab.nsyms == 0) {
        fclose(f);
        NOTEPIC_LOG("Error: LC_SYMTAB not found in binary");
        return;
    }

    char *strtab = (char *)malloc(symtab.strsize);
    if (!strtab) {
        fclose(f);
        return;
    }

    fseek(f, symtab.stroff, SEEK_SET);
    if (fread(strtab, 1, symtab.strsize, f) != symtab.strsize) {
        free(strtab);
        fclose(f);
        return;
    }

    fseek(f, symtab.symoff, SEEK_SET);

    void *p_pref = NULL;
    void *p_cand = NULL;

    struct nlist_64 entry;
    for (uint32_t i = 0; i < symtab.nsyms; i++) {
        if (fread(&entry, sizeof(entry), 1, f) != 1) break;
        if (entry.n_un.n_strx > 0 && entry.n_un.n_strx < symtab.strsize) {
            const char *name = strtab + entry.n_un.n_strx;
            if (!p_pref && strstr(name, "preferred_build_platform")) {
                p_pref = (void *)((uintptr_t)slide + entry.n_value);
            }
            if (!p_cand && strstr(name, "build_platform_candidates")) {
                p_cand = (void *)((uintptr_t)slide + entry.n_value);
            }
            if (p_pref && p_cand) break;
        }
    }

    free(strtab);
    fclose(f);

    if (p_pref) {
        int rc = DobbyHook(p_pref, (void *)np_hook_preferred_build_platform, NULL);
        NOTEPIC_LOG("Hooked preferred_build_platform at %p (rc=%d)", p_pref, rc);
    } else {
        NOTEPIC_LOG("Warning: Could not locate preferred_build_platform");
    }

    if (p_cand) {
        int rc = DobbyHook(p_cand, (void *)np_hook_build_platform_candidates, NULL);
        NOTEPIC_LOG("Hooked build_platform_candidates at %p (rc=%d)", p_cand, rc);
    } else {
        NOTEPIC_LOG("Warning: Could not locate build_platform_candidates");
    }
}

__attribute__((constructor))
static void notepic_init(void) {
    NOTEPIC_LOG("Bridgeplay notepic hook initialized (PID %d)", getpid());

    /* Clean any stale macOS-only platform cache so Epic probes Windows immediately */
    clear_stale_availability_cache();

    /* Hook posix_spawn / posix_spawnp to intercept .exe launches */
    DobbyHook((void *)posix_spawn, (void *)hook_posix_spawn, (void **)&orig_posix_spawn);
    DobbyHook((void *)posix_spawnp, (void *)hook_posix_spawnp, (void **)&orig_posix_spawnp);

    /* Hook platform candidate & preferred resolvers in main eglv2_lib binary */
    scan_and_hook_symbols();
}
