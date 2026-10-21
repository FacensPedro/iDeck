#include <stdio.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <spawn.h>

__attribute__((constructor))
void init_live_container_hook() {
    setenv("CFNETWORK_DIAGNOSTICS", "3", 1);
    setenv("OS_ACTIVITY_DT_MODE", "enable", 1);
}

void AMFI_bypass() {
    void *handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW);
    if (handle) {
        void *symbol = dlsym(handle, "CFBundleGetBundleWithIdentifier");
        if (symbol) {
            mprotect((void *)(((uintptr_t)symbol) & ~0x3FFF), 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC);
        }
    }
}

int custom_posix_spawn(pid_t *restrict pid, const char *restrict path,
                       const posix_spawn_file_actions_t *file_actions,
                       const posix_spawnattr_t *restrict attrp,
                       char *const argv[restrict],
                       char *const envp[restrict]) {
    
    char *new_envp[100];
    int env_count = 0;
    
    while (envp != NULL && envp[env_count] != NULL && env_count < 98) {
        new_envp[env_count] = envp[env_count];
        env_count++;
    }
    
    new_envp[env_count] = "DYLD_INSERT_LIBRARIES=@executable_path/LiveContainerHook.dylib";
    new_envp[env_count + 1] = NULL;
    
    return posix_spawn(pid, path, file_actions, attrp, argv, new_envp);
}
