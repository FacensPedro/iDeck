#ifndef IDECK_MADEIRA_RUNTIME_BRIDGE_H
#define IDECK_MADEIRA_RUNTIME_BRIDGE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
    IDECK_RUNTIME_OK = 0,
    IDECK_RUNTIME_INVALID_ARGUMENT = 22,
    IDECK_RUNTIME_NOT_AVAILABLE = 38,
    IDECK_RUNTIME_NOT_READY = 11
} IDeckRuntimeStatus;
bool ideck_fex_available(void);
bool ideck_fex_initialize(void);
// A live StikDebug-compatible debugger is needed until the FEX RX pool exists.
bool ideck_fex_jit_ready(void);
bool ideck_jit_debugger_attached(void);
bool ideck_wine_jit_pool_prepare(void);
bool ideck_wine_jit_pool_ready(void);
bool ideck_wineserver_available(void);
bool ideck_wineserver_initialize(const char *wine_prefix);
bool ideck_wineserver_ready(void);
bool ideck_wineprocess_available(void);
bool ideck_wineprocess_running(void);
bool ideck_wineprocess_request_close(void);
bool ideck_wineprocess_last_exit_code(int32_t *code);
bool ideck_wineprocess_last_ntstatus(uint32_t *code);
int32_t ideck_wineprocess_start(const char *wine_prefix);
bool ideck_dxmt_available(void);
bool ideck_d3d12_available(void);
bool ideck_metal_available(void);
void *ideck_metal_renderer_create(int32_t width, int32_t height);
void ideck_metal_renderer_destroy(void *renderer);
void *ideck_metal_renderer_texture(void *renderer);
void *ideck_jit_allocate(size_t size);
int32_t ideck_jit_make_executable(void *address, size_t size);
void ideck_jit_deallocate(void *address, size_t size);
int32_t ideck_runtime_prepare(const char *wine_prefix);
int32_t ideck_runtime_launch(const char *executable_path, const char *wine_prefix, const char *request_json);
#ifdef __cplusplus
}
#endif
#endif
