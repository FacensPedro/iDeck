#ifndef IDECK_RUNTIME_SUPPORT_H
#define IDECK_RUNTIME_SUPPORT_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void ideck_session_stop(void);
void ideck_controller_start(void);
void ideck_controller_stop_discovery(void);
void ideck_controller_stop(void);
void ideck_touch_gamepad_set_enabled(int enabled);
void ideck_touch_gamepad_set_state(uint16_t buttons, int16_t lx, int16_t ly,
                                   int16_t rx, int16_t ry,
                                   uint8_t left_trigger, uint8_t right_trigger);
#ifdef __cplusplus
}
#endif
#endif
