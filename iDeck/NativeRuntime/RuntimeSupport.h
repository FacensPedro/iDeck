#ifndef IDECK_RUNTIME_SUPPORT_H
#define IDECK_RUNTIME_SUPPORT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum { IDECK_SESSION_STOPPED=0, IDECK_SESSION_PREPARING=1, IDECK_SESSION_READY=2, IDECK_SESSION_FAILED=3 } IDeckSessionState;
int32_t ideck_session_prepare(const char *prefix);
void ideck_session_stop(void);
int32_t ideck_session_state(void);
void *ideck_fex_memory_reserve(size_t length);
void ideck_fex_memory_release(void *memory, size_t length);
int32_t ideck_wine_environment_configure(const char *prefix);
bool ideck_wine_dll_exists(const char *root, const char *name);
bool ideck_windows_to_unix_path(const char *prefix, const char *windows_path, char *output, size_t capacity);
void *ideck_metal_swapchain_create(void *metal_layer);
void ideck_metal_swapchain_destroy(void *swapchain);
bool ideck_metal_shader_library_available(void *metal_device);
void ideck_controller_start(void);
void ideck_controller_stop(void);
void ideck_touch_gamepad_set_enabled(int enabled);
void ideck_touch_gamepad_set_state(uint16_t buttons, int16_t lx, int16_t ly,
                                   int16_t rx, int16_t ry,
                                   uint8_t left_trigger, uint8_t right_trigger);
bool ideck_audio_session_activate(void);
void ideck_runtime_report_error(int32_t code, const char *message);
int32_t ideck_runtime_last_error(void);
#ifdef __cplusplus
}
#endif
#endif
