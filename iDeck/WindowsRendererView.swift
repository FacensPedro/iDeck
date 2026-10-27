import SwiftUI
import MetalKit
import QuartzCore
import Darwin

private final class MadeiraMetalView: MTKView {
    static var isAttachedAndSized = false
    var publishedSize: CGSize = .zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshSurface()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshSurface()
    }

    private func refreshSurface() {
        let requested = WindowsRendererView.requestedSize
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let target = requested ?? CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if target.width >= 2 && target.height >= 2 && drawableSize != target {
            drawableSize = target
        }
        let ready = window != nil && device != nil && drawableSize.width >= 2 && drawableSize.height >= 2
        WindowsRendererView.publishLayer(ready ? self : nil)
        Self.isAttachedAndSized = ready
    }
}

struct WindowsRendererView: UIViewRepresentable {
    static var isNativeDisplayLinked: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") != nil &&
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "macdrv_functions") != nil
    }

    static var isReadyForFrames: Bool {
        isNativeDisplayLinked && MadeiraMetalView.isAttachedAndSized
    }

    static var requestedSize: CGSize? {
        guard let w = getenv("MADEIRA_SCREEN_W"), let h = getenv("MADEIRA_SCREEN_H"),
              let width = Double(String(cString: w)), let height = Double(String(cString: h)),
              width.isFinite, height.isFinite,
              (320...7680).contains(width), (240...4320).contains(height) else { return nil }
        return CGSize(width: width, height: height)
    }

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
               (view as? MadeiraMetalView)?.publishedSize != drawableSize,
               let modeSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "winios_display_mode_changed") {
                let mode = unsafeBitCast(modeSymbol, to: DisplayModeChanged.self)
                (view as? MadeiraMetalView)?.publishedSize = drawableSize
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
        mtkView.autoResizeDrawable = false
        mtkView.framebufferOnly = false
        mtkView.contentMode = .scaleAspectFit
        setenv("MVK_CONFIG_IOS_SURFACE", "1", 1)
        MadeiraMetalView.isAttachedAndSized = false
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        publishLayer(nil)
        MadeiraMetalView.isAttachedAndSized = false
    }
}
