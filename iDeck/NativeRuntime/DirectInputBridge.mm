#import "RuntimeSupport.h"
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define IDECK_PAD_COUNT 4
#define IDECK_HID_TOUCHPAD 0x00010000u
#define IDECK_HID_L2 0x00040000u
#define IDECK_HID_R2 0x00080000u

// Exact public C layout from pinned Madeira/Winios/WiniosGamepad.h.
// Use runtime lookup so an interface-only IPA is not falsely native-enabled.
typedef struct {
    uint32_t packet;
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t lx, ly, rx, ry;
    uint8_t connected;
    uint8_t reserved[3];
} IDeckGamepad;
static_assert(sizeof(IDeckGamepad) == 20, "Madeira XInput layout mismatch");

typedef struct {
    uint32_t packet, buttons;
    int16_t lx, ly, rx, ry;
    uint8_t left_trigger, right_trigger, connected, battery;
    uint8_t charging, motion, touch[2], reserved[2];
    uint16_t touch_x[2], touch_y[2];
    int16_t gyro[3], accel[3];
    uint16_t reserved2;
} IDeckHIDPad;
static_assert(sizeof(IDeckHIDPad) == 48, "Madeira HID layout mismatch");

typedef void (*PadSetState)(int, const IDeckGamepad *);
typedef void (*HIDSetState)(const IDeckHIDPad *);
typedef void (*PadOutputConfigure)(int, int);
typedef void (*PadOutputSlot)(int, GCController *);
typedef void (*PadOutputActive)(int);
typedef void (*PadVibration)(int, uint16_t, uint16_t);

static GCController *g_slots[IDECK_PAD_COUNT] = {};
static id g_connectObserver;
static id g_disconnectObserver;
static id g_backgroundObserver;
static id g_foregroundObserver;
static dispatch_source_t g_sampleTimer;
static BOOL g_sessionActive = NO;
static BOOL g_appActive = YES;
static BOOL g_hidEnabled = NO;
static BOOL g_xinputEnabled = YES;
static BOOL g_hidXInput = NO;
static BOOL g_hasOutput = NO;
static BOOL g_observing = NO;
static BOOL g_touchEnabled = NO;
static IDeckGamepad g_touchState = {};

static void *pad_symbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static void publish_pad(int slot, const IDeckGamepad *state) {
    PadSetState fn = (PadSetState)pad_symbol("winios_gamepad_set_state");
    if (fn) fn(slot, state);
}

static void publish_hid(const IDeckHIDPad *state) {
    HIDSetState fn = (HIDSetState)pad_symbol("winios_hidpad_set_state");
    if (fn) fn(state);
}

static void output_slot(int index, GCController *pad) {
    PadOutputSlot fn = (PadOutputSlot)pad_symbol("madeira_pad_output_set_slot");
    if (fn) fn(index, pad);
}

static void output_active(BOOL on) {
    PadOutputActive fn = (PadOutputActive)pad_symbol("madeira_pad_output_set_active");
    if (fn) fn(on ? 1 : 0);
}

static void output_config(int xinput, int hid) {
    PadOutputConfigure fn = (PadOutputConfigure)pad_symbol("madeira_pad_output_configure");
    if (fn) fn(xinput, hid);
}

static void zero_vibration(int index) {
    PadVibration fn = (PadVibration)pad_symbol("winios_gamepad_set_vibration");
    if (fn) fn(index, 0, 0);
}

static uint8_t trigger(float value) {
    return isfinite(value) ? (uint8_t)lrintf(fmaxf(0, fminf(1, value)) * 255) : 0;
}
static int16_t axis(float value) {
    if (!isfinite(value)) return 0;
    float v = fmaxf(-1, fminf(1, value));
    return (int16_t)lrintf(v * (v < 0 ? 32768.0f : 32767.0f));
}
static uint16_t buttons_for_pad(GCExtendedGamepad *pad) {
    uint16_t buttons = 0;
    if (pad.dpad.up.isPressed) buttons |= 0x0001;
    if (pad.dpad.down.isPressed) buttons |= 0x0002;
    if (pad.dpad.left.isPressed) buttons |= 0x0004;
    if (pad.dpad.right.isPressed) buttons |= 0x0008;
    if (pad.buttonMenu.isPressed) buttons |= 0x0010;
    if (pad.buttonOptions.isPressed) buttons |= 0x0020;
    if (pad.leftThumbstickButton.isPressed) buttons |= 0x0040;
    if (pad.rightThumbstickButton.isPressed) buttons |= 0x0080;
    if (pad.leftShoulder.isPressed) buttons |= 0x0100;
    if (pad.rightShoulder.isPressed) buttons |= 0x0200;
    if (pad.buttonHome.isPressed) buttons |= 0x0400;
    if (pad.buttonA.isPressed) buttons |= 0x1000;
    if (pad.buttonB.isPressed) buttons |= 0x2000;
    if (pad.buttonX.isPressed) buttons |= 0x4000;
    if (pad.buttonY.isPressed) buttons |= 0x8000;
    return buttons;
}

static void sample_gamepads(void) {
    if (!g_sessionActive) return;
    if (!g_xinputEnabled) {
        for (int i = 0; i < IDECK_PAD_COUNT; ++i) publish_pad(i, NULL);
        publish_hid(NULL);
        return;
    }
    int virtualSlot = -1;
    if (g_touchEnabled && g_appActive) {
        for (int i = 0; i < IDECK_PAD_COUNT; ++i)
            if (!g_slots[i]) { virtualSlot = i; break; }
    }
    for (int i = 0; i < IDECK_PAD_COUNT; ++i) {
        GCController *controller = g_slots[i];
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) {
            if (i == virtualSlot) {
                IDeckGamepad state = g_touchState;
                state.connected = 1;
                publish_pad(i, &state);
                if (i == 0 && g_hidEnabled) {
                    IDeckHIDPad hid = {};
                    hid.connected = 1;
                    hid.battery = 0xff;
                    hid.buttons = state.buttons;
                    hid.left_trigger = state.left_trigger;
                    hid.right_trigger = state.right_trigger;
                    hid.lx = state.lx; hid.ly = state.ly;
                    hid.rx = state.rx; hid.ry = state.ry;
                    publish_hid(&hid);
                    if (!g_hidXInput) publish_pad(i, NULL);
                }
            } else {
                publish_pad(i, NULL);
                if (i == 0 && g_hidEnabled) publish_hid(NULL);
            }
            continue;
        }
        IDeckGamepad state = {};
        state.connected = 1;
        if (g_appActive) {
            state.buttons = buttons_for_pad(pad);
            state.left_trigger = trigger(pad.leftTrigger.value);
            state.right_trigger = trigger(pad.rightTrigger.value);
            state.lx = axis(pad.leftThumbstick.xAxis.value);
            state.ly = axis(pad.leftThumbstick.yAxis.value);
            state.rx = axis(pad.rightThumbstick.xAxis.value);
            state.ry = axis(pad.rightThumbstick.yAxis.value);
        }
        if (i == 0 && g_hidEnabled) {
            IDeckHIDPad hid = {};
            hid.connected = 1;
            hid.buttons = state.buttons;
            hid.left_trigger = state.left_trigger;
            hid.right_trigger = state.right_trigger;
            hid.lx = state.lx; hid.ly = state.ly;
            hid.rx = state.rx; hid.ry = state.ry;
            if (state.left_trigger > 25) hid.buttons |= IDECK_HID_L2;
            if (state.right_trigger > 25) hid.buttons |= IDECK_HID_R2;
            GCControllerButtonInput *touch = nil;
            if ([pad isKindOfClass:[GCDualSenseGamepad class]])
                touch = ((GCDualSenseGamepad *)pad).touchpadButton;
            else if ([pad isKindOfClass:[GCDualShockGamepad class]])
                touch = ((GCDualShockGamepad *)pad).touchpadButton;
            if (g_appActive && touch.isPressed) hid.buttons |= IDECK_HID_TOUCHPAD;
            hid.battery = 0xff;
            GCDeviceBattery *battery = controller.battery;
            if (battery && battery.batteryState != GCDeviceBatteryStateUnknown) {
                hid.battery = (uint8_t)lrintf(fmaxf(0, fminf(1, battery.batteryLevel)) * 100);
                hid.charging = battery.batteryState == GCDeviceBatteryStateCharging ? 1 :
                               battery.batteryState == GCDeviceBatteryStateFull ? 2 : 0;
            }
            publish_hid(&hid);
            if (!g_hidXInput) {
                publish_pad(i, NULL);
                continue;
            }
        }
        publish_pad(i, &state);
    }
}

static void update_sample_timer(void) {
    BOOL hasController = NO;
    for (int i = 0; i < IDECK_PAD_COUNT; ++i)
        if (g_slots[i]) { hasController = YES; break; }
    BOOL needed = g_sessionActive && g_appActive && g_xinputEnabled && (hasController || g_touchEnabled);
    if (!needed) {
        if (g_sampleTimer) { dispatch_source_cancel(g_sampleTimer); g_sampleTimer = nil; }
        return;
    }
    if (g_sampleTimer) return;
    g_sampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_sampleTimer, DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_sampleTimer, ^{ sample_gamepads(); });
    dispatch_resume(g_sampleTimer);
}

static void refresh_controllers(void) {
    if (!g_sessionActive) return;
    NSArray<GCController *> *all = [GCController controllers];
    for (int i = 0; i < IDECK_PAD_COUNT; ++i) {
        GCController *old = g_slots[i];
        if (old && (![all containsObject:old] || !old.extendedGamepad)) {
            g_slots[i] = nil;
            output_slot(i, nil);
            zero_vibration(i);
            publish_pad(i, NULL);
            if (i == 0 && g_hidEnabled) publish_hid(NULL);
        }
    }
    for (GCController *controller in all) {
        if (!controller.extendedGamepad) continue;
        BOOL assigned = NO;
        for (int i = 0; i < IDECK_PAD_COUNT; ++i)
            if (g_slots[i] == controller) { assigned = YES; break; }
        if (assigned) continue;
        for (int i = 0; i < IDECK_PAD_COUNT; ++i) {
            if (g_slots[i]) continue;
            g_slots[i] = controller;
            zero_vibration(i);
            output_slot(i, controller);
            fprintf(stderr, "[iDeck gamepad] slot %d connected: %s\n", i, controller.vendorName.UTF8String ?: "unknown");
            break;
        }
    }
    sample_gamepads();
    update_sample_timer();
}

static void begin_native_gamepads(void) {
    if (g_sessionActive) return;
    const char *mode = getenv("MADEIRA_PAD_MODE");
    const char *enabled = getenv("MADEIRA_XINPUT");
    const BOOL supported = pad_symbol("winios_gamepad_set_state") &&
                           pad_symbol("winios_hidpad_set_state");
    if (!supported) return;
    g_hidEnabled = mode && (!strcmp(mode, "hid") ||
                             !strcmp(mode, "dualsense") || !strcmp(mode, "generic"));
    g_hidXInput = getenv("MADEIRA_HIDPAD_XINPUT") &&
                  !strcmp(getenv("MADEIRA_HIDPAD_XINPUT"), "1");
    unsetenv("MADEIRA_HIDPAD");
    unsetenv("MADEIRA_HIDPAD_NAME");
    g_xinputEnabled = !enabled || strcmp(enabled, "0") != 0;
    if (!g_xinputEnabled) g_hidEnabled = NO;
    if (g_hidEnabled) {
        GCController *first = nil;
        for (GCController *controller in [GCController controllers]) {
            if (controller.extendedGamepad) { first = controller; break; }
        }
        BOOL sony = !first || [first.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]] ||
                            [first.extendedGamepad isKindOfClass:[GCDualShockGamepad class]];
        const char *kind = !strcmp(mode, "hid") ? (sony ? "dualsense" : "generic") : mode;
        setenv("MADEIRA_HIDPAD", kind, 1);
        if (!strcmp(kind, "generic") && first.vendorName)
            setenv("MADEIRA_HIDPAD_NAME", first.vendorName.UTF8String, 1);
    }
    const char *output = getenv("MADEIRA_PAD_OUTPUT");
    BOOL allowOutput = !output || (strcmp(output, "0") && strcmp(output, "off"));
    BOOL xinputOutput = allowOutput && (!output || strcmp(output, "hid") != 0) &&
                        !(enabled && !strcmp(enabled, "0"));
    BOOL hidOutput = allowOutput && (!output || strcmp(output, "xinput") != 0);
    g_hasOutput = allowOutput;
    output_config(xinputOutput ? 1 : 0, (g_hidEnabled && hidOutput) ? 1 : 0);
    g_appActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    g_sessionActive = YES;
    if (!g_observing) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        g_connectObserver = [center addObserverForName:GCControllerDidConnectNotification object:nil
                                                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { refresh_controllers(); }];
        g_disconnectObserver = [center addObserverForName:GCControllerDidDisconnectNotification object:nil
                                                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { refresh_controllers(); }];
        g_backgroundObserver = [center addObserverForName:UIApplicationWillResignActiveNotification object:nil
                                                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            g_appActive = NO;
            // The finger-up may never be delivered when iOS backgrounds a
            // game. Discard held virtual buttons/sticks before foreground.
            g_touchState = {};
            output_active(NO);
            sample_gamepads();
            update_sample_timer();
        }];
        g_foregroundObserver = [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            g_appActive = YES; output_active(YES); refresh_controllers();
        }];
        g_observing = YES;
    }
    refresh_controllers();
    fprintf(stderr, "[iDeck gamepad] session started; xinput=4 hid=%d output=%d\n", g_hidEnabled, g_hasOutput);
}

extern "C" void ideck_gamepad_begin_session(void) {
    if (NSThread.isMainThread) begin_native_gamepads();
    else dispatch_sync(dispatch_get_main_queue(), ^{ begin_native_gamepads(); });
}

static void stop_native_gamepads(void) {
    g_sessionActive = NO;
    if (g_sampleTimer) { dispatch_source_cancel(g_sampleTimer); g_sampleTimer = nil; }
    if (g_observing) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (id observer in @[g_connectObserver, g_disconnectObserver, g_backgroundObserver, g_foregroundObserver])
            [center removeObserver:observer];
        g_connectObserver = g_disconnectObserver = g_backgroundObserver = g_foregroundObserver = nil;
        g_observing = NO;
    }
    output_active(NO);
    output_config(0, 0);
    for (int i = 0; i < IDECK_PAD_COUNT; ++i) {
        publish_pad(i, NULL);
        zero_vibration(i);
        output_slot(i, nil);
        g_slots[i] = nil;
    }
    publish_hid(NULL);
    g_touchState = {};
    g_touchEnabled = NO;
    g_hidEnabled = NO;
    g_xinputEnabled = YES;
    g_hidXInput = NO;
    g_hasOutput = NO;
    unsetenv("MADEIRA_HIDPAD");
    unsetenv("MADEIRA_HIDPAD_NAME");
    fprintf(stderr, "[iDeck gamepad] session stopped, 4 XInput slots and HID cleared\n");
}

extern "C" void ideck_gamepad_end_session(void) {
    if (NSThread.isMainThread) stop_native_gamepads();
    else dispatch_sync(dispatch_get_main_queue(), ^{ stop_native_gamepads(); });
}

extern "C" void ideck_touch_gamepad_set_enabled(int enabled) {
    dispatch_block_t apply = ^{
        g_touchEnabled = enabled != 0;
        if (!g_touchEnabled) g_touchState = {};
        if (g_sessionActive) {
            sample_gamepads();
            update_sample_timer();
        }
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

extern "C" void ideck_touch_gamepad_set_state(uint16_t buttons,
                                               int16_t lx, int16_t ly,
                                               int16_t rx, int16_t ry,
                                               uint8_t left_trigger,
                                               uint8_t right_trigger) {
    dispatch_block_t apply = ^{
        if (!g_touchEnabled) return;
        g_touchState.buttons = buttons;
        g_touchState.lx = lx;
        g_touchState.ly = ly;
        g_touchState.rx = rx;
        g_touchState.ry = ry;
        g_touchState.left_trigger = left_trigger;
        g_touchState.right_trigger = right_trigger;
        g_touchState.connected = 1;
        ++g_touchState.packet;
        if (g_sessionActive) sample_gamepads();
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

extern "C" void ideck_controller_start(void) {
    if (NSThread.isMainThread) [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    else dispatch_async(dispatch_get_main_queue(), ^{ [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil]; });
}

extern "C" void ideck_controller_stop_discovery(void) {
    if (NSThread.isMainThread) [GCController stopWirelessControllerDiscovery];
    else dispatch_async(dispatch_get_main_queue(), ^{ [GCController stopWirelessControllerDiscovery]; });
}

extern "C" void ideck_controller_stop(void) {
    ideck_gamepad_end_session();
    ideck_controller_stop_discovery();
}
