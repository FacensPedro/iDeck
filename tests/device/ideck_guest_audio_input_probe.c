#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <xinput.h>
#include <stdio.h>
#include <stdint.h>

#ifndef IDECK_GUEST_BITS
#define IDECK_GUEST_BITS 64
#endif

#define PROBE_DURATION_MS 30000u
#define AUDIO_SAMPLES 24000
static volatile LONG touch_events = 0;
static volatile LONG click_events = 0;

static LRESULT CALLBACK probe_window(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_LBUTTONDOWN || message == WM_TOUCH) {
        InterlockedIncrement(&touch_events);
        InvalidateRect(window, NULL, TRUE);
        if (message == WM_TOUCH) {
            CloseTouchInputHandle((HTOUCHINPUT)l);
            return 0;
        }
    }
    if (message == WM_KEYDOWN || message == WM_LBUTTONDOWN) {
        InterlockedIncrement(&click_events);
    }
    if (message == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(window, &ps);
        const wchar_t text[] = L"iDeck Windows guest: tap screen, press controller A. Listen for tone.";
        TextOutW(dc, 10, 20, text, (int)(sizeof(text) / sizeof(text[0]) - 1));
        EndPaint(window, &ps);
        return 0;
    }
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

static int write_receipt(int audio_submitted, int audio_completed,
                         int controller_seen, int controller_pressed, int touch_seen) {
    char temp[MAX_PATH] = {0};
    char path[MAX_PATH] = {0};
    DWORD n = GetTempPathA(MAX_PATH, temp);
    if (!n || n >= MAX_PATH ||
        snprintf(path, sizeof(path), "%sideck-guest-audio-input-%u.log",
                 temp, (unsigned)IDECK_GUEST_BITS) >= (int)sizeof(path))
        return 30;
    FILE *file = fopen(path, "wb");
    if (!file) return 31;
    int count = fprintf(file, "ideck_guest_probe=audio-input-v1\r\n"
        "guest_arch=%u\r\npid=%lu\r\n"
        "waveout_submitted=%d\r\nwaveout_completed=%d\r\n"
        "xinput_connected=%d\r\nxinput_button_event=%d\r\n"
        "touch_event=%d\r\n",
        (unsigned)IDECK_GUEST_BITS, (unsigned long)GetCurrentProcessId(),
        audio_submitted, audio_completed, controller_seen, controller_pressed, touch_seen);
    int closed = fclose(file);
    printf("ideck guest audio/input arch=%u audio=%d/%d controller=%d/%d touch=%d\n",
           (unsigned)IDECK_GUEST_BITS, audio_submitted, audio_completed,
           controller_seen, controller_pressed, touch_seen);
    fflush(stdout);
    return count > 0 && !closed ? 0 : 32;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command, int show) {
    (void)previous;
    (void)command;
    WNDCLASSW klass = {0};
    klass.hInstance = instance;
    klass.lpfnWndProc = probe_window;
    klass.lpszClassName = L"iDeck Guest Audio and Controller Probe";
    if (!RegisterClassW(&klass)) return 10;

    HWND window = CreateWindowW(klass.lpszClassName, L"iDeck PE32/PE32+ audio and input",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT,
        740, 180, NULL, NULL, instance, NULL);
    if (!window) return 11;
    ShowWindow(window, show);
    RegisterTouchWindow(window, 0);

    WAVEFORMATEX format = {0};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = 48000;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 2;
    format.nAvgBytesPerSec = 96000;

    int16_t samples[AUDIO_SAMPLES];
    for (int i = 0; i < AUDIO_SAMPLES; ++i) {
        unsigned int period = (unsigned int)i % 109u;
        int triangle = period < 55u ? (int)period : (int)(109u - period);
        samples[i] = (int16_t)((triangle - 27) * 650);
    }

    HWAVEOUT audio = NULL;
    WAVEHDR header = {0};
    int audio_submitted = 0, audio_completed = 0;
    MMRESULT result = waveOutOpen(&audio, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL);
    if (result == MMSYSERR_NOERROR) {
        header.lpData = (LPSTR)samples;
        header.dwBufferLength = sizeof(samples);
        if (waveOutPrepareHeader(audio, &header, sizeof(header)) == MMSYSERR_NOERROR) {
            if (waveOutWrite(audio, &header, sizeof(header)) == MMSYSERR_NOERROR)
                audio_submitted = 1;
        }
    }

    int controller_seen = 0, controller_pressed = 0;
    DWORD started = GetTickCount();
    int running = 1;
    while (running && (DWORD)(GetTickCount() - started) < PROBE_DURATION_MS) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) running = 0;
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (audio_submitted && (header.dwFlags & WHDR_DONE))
            audio_completed = 1;
        for (DWORD index = 0; index < 4; ++index) {
            XINPUT_STATE state = {0};
            if (XInputGetState(index, &state) == ERROR_SUCCESS) {
                controller_seen = 1;
                if (state.Gamepad.wButtons & (XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_START))
                    controller_pressed = 1;
            }
        }
        if (audio_completed && controller_pressed && touch_events) break;
        Sleep(20);
    }

    if (audio) {
        waveOutReset(audio);
        if (header.dwFlags & WHDR_PREPARED)
            waveOutUnprepareHeader(audio, &header, sizeof(header));
        waveOutClose(audio);
    }
    int receipt = write_receipt(audio_submitted, audio_completed,
        controller_seen, controller_pressed, touch_events != 0);
    DestroyWindow(window);
    if (receipt != 0) return receipt;
    if (!audio_submitted || !audio_completed) return 20;
    if (!controller_seen || !controller_pressed) return 21;
    if (!touch_events) return 22;
    return 0;
}
