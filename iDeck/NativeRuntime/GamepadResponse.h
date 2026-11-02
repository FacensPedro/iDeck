#ifndef IDECK_GAMEPAD_RESPONSE_H
#define IDECK_GAMEPAD_RESPONSE_H

#include <math.h>
#include <stdint.h>

// Pure C: identical calibrated axes are sent to Madeira XInput and virtual HID.
// A radial dead zone removes stick drift without clipping diagonals. Both
// controls in Settings modify real guest input rather than only the UI.
typedef struct {
    int16_t x;
    int16_t y;
} IDeckPadStick;

static inline float ideck_pad_limit(float value, float low, float high) {
    if (!isfinite(value)) return low;
    return fminf(high, fmaxf(low, value));
}

static inline int16_t ideck_pad_axis(float value) {
    float v = ideck_pad_limit(value, -1.0f, 1.0f);
    return (int16_t)lrintf(v * (v < 0.0f ? 32768.0f : 32767.0f));
}

static inline IDeckPadStick ideck_pad_stick(float x, float y,
                                            float sensitivity, float deadzone) {
    IDeckPadStick neutral = {0, 0};
    if (!isfinite(x) || !isfinite(y)) return neutral;

    x = ideck_pad_limit(x, -1.0f, 1.0f);
    y = ideck_pad_limit(y, -1.0f, 1.0f);
    sensitivity = ideck_pad_limit(sensitivity, 0.25f, 2.0f);
    deadzone = ideck_pad_limit(deadzone, 0.0f, 0.35f);

    float magnitude = hypotf(x, y);
    if (magnitude <= deadzone || magnitude == 0.0f) return neutral;

    // Remap the active radius to [0,1], then apply sensitivity. Clamp the
    // resulting magnitude (not each axis independently) to preserve angle.
    float response = fminf(1.0f,
                          fminf(magnitude, 1.0f) - deadzone > 0.0f
                              ? ((fminf(magnitude, 1.0f) - deadzone) /
                                 (1.0f - deadzone)) * sensitivity
                              : 0.0f);
    float scale = response / magnitude;
    IDeckPadStick calibrated = {
        ideck_pad_axis(x * scale),
        ideck_pad_axis(y * scale)
    };
    return calibrated;
}

#endif
