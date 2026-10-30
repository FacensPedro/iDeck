#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <cstdio>

static void write_guest_frame_receipt(const char *api, unsigned int frames,
                                      unsigned long hresult, int status) {
    char directory[MAX_PATH] = {};
    char filename[MAX_PATH] = {};
    DWORD used = GetTempPathA(MAX_PATH, directory);
    if (!used || used >= MAX_PATH ||
        std::snprintf(filename, sizeof(filename),
            "%sideck-guest-%s-frame.log", directory, api) >= (int)sizeof(filename))
        return;
    FILE *file = std::fopen(filename, "wb");
    if (!file) return;
    if (status == 0 && frames > 0) {
        if (api[4] == '1') {
            std::fprintf(file, "ideck-d3d11-frame-probe: presents=%u hr=0x%08lx\r\n",
                         frames, hresult);
        } else {
            std::fprintf(file, "ideck-d3d12-frame-probe: presents=%u hr=0x%08lx exit=%d\r\n",
                         frames, hresult, status);
        }
    } else {
        std::fprintf(file, "ideck-%s-frame-failure: presents=%u hr=0x%08lx exit=%d\r\n",
                     api, frames, hresult, status);
    }
    std::fclose(file);
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

template<typename T> static void release(T *&value) {
    if (value) value->Release();
    value = nullptr;
}

static int run(HWND window) {
    HRESULT hr = S_OK;
    IDXGIFactory4 *factory = nullptr;
    ID3D12Device *device = nullptr;
    ID3D12CommandQueue *queue = nullptr;
    IDXGISwapChain1 *basic_swapchain = nullptr;
    IDXGISwapChain3 *swapchain = nullptr;
    ID3D12DescriptorHeap *rtv_heap = nullptr;
    ID3D12CommandAllocator *allocator = nullptr;
    ID3D12GraphicsCommandList *commands = nullptr;
    ID3D12Fence *fence = nullptr;
    ID3D12Resource *buffers[2] = {nullptr, nullptr};
    HANDLE fence_event = NULL;
    UINT frames = 0;
    const UINT buffer_count = 2;
    UINT rtv_stride = 0;
    D3D12_CPU_DESCRIPTOR_HANDLE cpu_rtv[2] = {};
    UINT64 fence_value = 0;
    int status = 20;

    hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) goto cleanup;
    hr = D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device));
    if (FAILED(hr)) goto cleanup;

    {
        D3D12_COMMAND_QUEUE_DESC queue_desc = {};
        queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        hr = device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&queue));
    }
    if (FAILED(hr)) goto cleanup;
    {
        DXGI_SWAP_CHAIN_DESC1 swap_desc = {};
        swap_desc.Width = 640;
        swap_desc.Height = 360;
        swap_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        swap_desc.SampleDesc.Count = 1;
        swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        swap_desc.BufferCount = buffer_count;
        swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        hr = factory->CreateSwapChainForHwnd(queue, window, &swap_desc,
                                              nullptr, nullptr, &basic_swapchain);
    }
    if (FAILED(hr)) goto cleanup;
    hr = basic_swapchain->QueryInterface(IID_PPV_ARGS(&swapchain));
    if (FAILED(hr)) goto cleanup;
    {
        D3D12_DESCRIPTOR_HEAP_DESC heap_desc = {};
        heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        heap_desc.NumDescriptors = buffer_count;
        hr = device->CreateDescriptorHeap(&heap_desc, IID_PPV_ARGS(&rtv_heap));
    }
    if (FAILED(hr)) goto cleanup;
    rtv_stride = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    {
        D3D12_CPU_DESCRIPTOR_HANDLE base = rtv_heap->GetCPUDescriptorHandleForHeapStart();
        for (UINT i = 0; i < buffer_count; ++i) {
            hr = swapchain->GetBuffer(i, IID_PPV_ARGS(&buffers[i]));
            if (FAILED(hr)) goto cleanup;
            cpu_rtv[i].ptr = base.ptr + (SIZE_T)i * rtv_stride;
            device->CreateRenderTargetView(buffers[i], nullptr, cpu_rtv[i]);
        }
    }
    hr = device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator));
    if (FAILED(hr)) goto cleanup;
    hr = device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator,
                                   nullptr, IID_PPV_ARGS(&commands));
    if (FAILED(hr)) goto cleanup;
    hr = commands->Close();
    if (FAILED(hr)) goto cleanup;
    hr = device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence));
    if (FAILED(hr)) goto cleanup;
    fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!fence_event) goto cleanup;

    for (; frames < 120; ++frames) {
        MSG message = {};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                status = 24;
                goto cleanup;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        const UINT frame_index = swapchain->GetCurrentBackBufferIndex();
        hr = allocator->Reset();
        if (FAILED(hr)) goto cleanup;
        hr = commands->Reset(allocator, nullptr);
        if (FAILED(hr)) goto cleanup;

        D3D12_RESOURCE_BARRIER transition = {};
        transition.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        transition.Transition.pResource = buffers[frame_index];
        transition.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        transition.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        transition.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        commands->ResourceBarrier(1, &transition);
        const float color[4] = {
            (frames / 30) % 2 ? 0.1f : 0.85f, 0.15f,
            (frames / 30) % 2 ? 0.85f : 0.1f, 1.0f
        };
        commands->OMSetRenderTargets(1, &cpu_rtv[frame_index], FALSE, nullptr);
        commands->ClearRenderTargetView(cpu_rtv[frame_index], color, 0, nullptr);
        transition.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        transition.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        commands->ResourceBarrier(1, &transition);
        hr = commands->Close();
        if (FAILED(hr)) goto cleanup;
        ID3D12CommandList *submitted[] = {commands};
        queue->ExecuteCommandLists(1, submitted);
        hr = swapchain->Present(1, 0);
        if (FAILED(hr)) goto cleanup;
        ++fence_value;
        hr = queue->Signal(fence, fence_value);
        if (FAILED(hr)) goto cleanup;
        if (fence->GetCompletedValue() < fence_value) {
            hr = fence->SetEventOnCompletion(fence_value, fence_event);
            if (FAILED(hr) || WaitForSingleObject(fence_event, 4000) != WAIT_OBJECT_0) {
                status = 23;
                goto cleanup;
            }
        }
    }
    status = 0;

cleanup:
    write_guest_frame_receipt("d3d12", frames, (unsigned long)hr, status);
    std::printf("ideck-d3d12-frame-probe: presents=%u hr=0x%08lx exit=%d\n",
                frames, (unsigned long)hr, status);
    std::fflush(stdout);
    if (fence_event) CloseHandle(fence_event);
    release(fence);
    release(commands);
    release(allocator);
    for (auto &buffer : buffers) release(buffer);
    release(rtv_heap);
    release(swapchain);
    release(basic_swapchain);
    release(queue);
    release(device);
    release(factory);
    return status;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    WNDCLASSW klass = {};
    klass.hInstance = instance;
    klass.lpfnWndProc = window_proc;
    klass.lpszClassName = L"iDeck Guest D3D12 Frame Probe";
    if (!RegisterClassW(&klass)) return 10;
    HWND window = CreateWindowW(klass.lpszClassName,
        L"iDeck Windows guest Direct3D 12: alternating red and blue",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT,
        640, 360, nullptr, nullptr, instance, nullptr);
    if (!window) return 11;
    int status = run(window);
    DestroyWindow(window);
    return status;
}
