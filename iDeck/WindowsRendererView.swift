import SwiftUI
import MetalKit
import QuartzCore
import Darwin

private final class MadeiraMetalView: MTKView {
    override func layoutSubviews() {
        super.layoutSubviews()
        WindowsRendererView.publishLayer(self)
    }
}

struct WindowsRendererView: UIViewRepresentable {
    private typealias SetMetalLayer = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias DisplayModeChanged = @convention(c) (Int32, Int32) -> Void

    fileprivate static func publishLayer(_ view: MTKView?) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") else {
            return
        }
        let callback = unsafeBitCast(symbol, to: SetMetalLayer.self)
        if let view, let layer = view.layer as? CAMetalLayer {
            callback(Unmanaged.passUnretained(layer).toOpaque())
            let drawableSize = view.drawableSize
            if drawableSize.width >= 2 && drawableSize.height >= 2,
               let modeSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "winios_display_mode_changed") {
                let mode = unsafeBitCast(modeSymbol, to: DisplayModeChanged.self)
                mode(Int32(max(1, min(drawableSize.width, 8192))),
                     Int32(max(1, min(drawableSize.height, 8192))))
            }
        } else {
            callback(nil)
        }
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MadeiraMetalView(frame: .zero)
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
        mtkView.isOpaque = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.autoResizeDrawable = true
        mtkView.framebufferOnly = false
        mtkView.contentMode = .scaleAspectFit
        setenv("MVK_CONFIG_IOS_SURFACE", "1", 1)
        Self.publishLayer(mtkView)
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.setNeedsLayout()
        Self.publishLayer(uiView)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        publishLayer(nil)
    }
}
