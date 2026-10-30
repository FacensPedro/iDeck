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
typedef struct {
    bool debugger_attached;
    bool fex_initialized;
    bool fex_state_busy;
    bool wine_pool_prepared;
    bool wine_state_busy;
    bool rx_executable;
    bool rw_writable;
    int32_t wine_failure_stage;
    int32_t wine_failure_rx_detail;
    int32_t wine_failure_mach_code;
    uint32_t wine_pool_mib;
} IDeckJITSnapshot;
IDeckJITSnapshot ideck_jit_snapshot(void);
// Detailed native failure stage: 0 none, 1 debugger, 2 RX allocation,
// 3 RX validation, 4 RW remap, 5 RW protection, 6 environment export.
int32_t ideck_wine_jit_pool_failure_stage(void);
int32_t ideck_wine_jit_pool_failure_mach_code(void);
// RX reject detail: 1 low address, 2 overflow, 3 unsupported upper range,
// 4 overlaps guest PE window, 5 unaligned, 6 vm_region error,
// 7 region gap, 8 non-executable page.
int32_t ideck_wine_jit_pool_failure_rx_detail(void);
bool ideck_wineserver_available(void);
bool ideck_wineserver_initialize(const char *wine_prefix);
bool ideck_wineserver_ready(void);
bool ideck_wineserver_running(void);
void ideck_gamepad_begin_session(void);
void ideck_gamepad_end_session(void);
bool ideck_wineprocess_available(void);
bool ideck_wineprocess_running(void);
bool ideck_wineprocess_thread_finished(void);
bool ideck_wineprocess_request_close(void);
// Only complete after both Wine's guest thread and its wineserver have exited.
bool ideck_runtime_complete_session(void);
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
