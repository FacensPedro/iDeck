#ifndef IDECK_MADEIRA_STATIC_ABI_H
#define IDECK_MADEIRA_STATIC_ABI_H

#include <stdbool.h>
#include <stdint.h>

#if defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED
#ifdef __cplusplus
extern "C" {
#endif

/* ABI of pinned Madeira headers plus iDeck's repeat-session patch.
 * Strong references make a missing native implementation a linker error. */
bool fex_initialize(void);
int wineserver_start(const char *prefix_path);
int wineserver_is_running(void);
int wineserver_is_ready(void);
int wine_process_start(const char *prefix_path);
int wine_process_is_running(void);
int wine_process_thread_finished(void);
int wine_process_exit_code(void);
int wine_crash_exit_status(uint32_t *status);
void winios_post_key(int vk, int down);
uint64_t madeira_get_present_count(void);
int madeira_d3d12_canary_run(const char *fixture_dir, const char *dylib_path,
                             void (*sink)(const char *));

#ifdef __cplusplus
}
#endif
#endif
#endif
