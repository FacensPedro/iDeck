#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <cstdio>

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM word, LPARAM longword) {
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, word, longword);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    WNDCLASSW window_class = {};
    window_class.hInstance = instance;
    window_class.lpfnWndProc = window_proc;
    window_class.lpszClassName = L"iDeck Guest D3D11 Frame Probe";
    if (!RegisterClassW(&window_class)) return 11;

    HWND window = CreateWindowW(window_class.lpszClassName,
        L"iDeck real guest Direct3D 11 frame probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 640, 360, NULL, NULL, instance, NULL);
    if (!window) return 12;

    DXGI_SWAP_CHAIN_DESC descriptor = {};
    descriptor.BufferDesc.Width = 640;
    descriptor.BufferDesc.Height = 360;
    descriptor.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    descriptor.SampleDesc.Count = 1;
    descriptor.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    descriptor.BufferCount = 2;
    descriptor.OutputWindow = window;
    descriptor.Windowed = TRUE;
    descriptor.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain *swapchain = nullptr;
    ID3D11Device *device = nullptr;
    ID3D11DeviceContext *context = nullptr;
    D3D_FEATURE_LEVEL feature = {};
    HRESULT result = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
        D3D11_SDK_VERSION, &descriptor, &swapchain, &device, &feature, &context);
    if (FAILED(result)) {
        std::fprintf(stderr, "iDeck D3D11 device/swap chain creation failed: 0x%08lx\n", (unsigned long)result);
        DestroyWindow(window);
        return 13;
    }

    ID3D11Texture2D *backbuffer = nullptr;
    result = swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D),
                                  reinterpret_cast<void **>(&backbuffer));
    ID3D11RenderTargetView *render_target = nullptr;
    if (SUCCEEDED(result)) {
        result = device->CreateRenderTargetView(backbuffer, nullptr, &render_target);
    }
    if (backbuffer) backbuffer->Release();
    if (FAILED(result) || !render_target) {
        if (context) context->Release();
        if (device) device->Release();
        if (swapchain) swapchain->Release();
        DestroyWindow(window);
        return 14;
    }

    int frames = 0;
    for (; frames < 180; ++frames) {
        MSG message = {};
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        const float red = (frames / 30) % 2 ? 0.15f : 0.85f;
        const float blue = (frames / 30) % 2 ? 0.85f : 0.15f;
        const float clear[4] = {red, 0.2f, blue, 1.0f};
        context->OMSetRenderTargets(1, &render_target, nullptr);
        context->ClearRenderTargetView(render_target, clear);
        result = swapchain->Present(1, 0);
        if (FAILED(result)) break;
        Sleep(16);
    }

    std::printf("ideck-d3d11-frame-probe: presents=%d hr=0x%08lx\n",
                frames, (unsigned long)result);
    std::fflush(stdout);
    render_target->Release();
    context->Release();
    device->Release();
    swapchain->Release();
    DestroyWindow(window);
    return SUCCEEDED(result) && frames == 180 ? 0 : 15;
}
