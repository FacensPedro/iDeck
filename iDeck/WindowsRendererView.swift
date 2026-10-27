import SwiftUI
import MetalKit
import QuartzCore
import Darwin

private final class MadeiraMetalView: MTKView {
    var publishedSize: CGSize = .zero
    var generation = 0

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
        if window != nil && device != nil && drawableSize.width >= 2 && drawableSize.height >= 2 {
            WindowsRendererView.publishLayer(self)
        } else {
            WindowsRendererView.releaseLayer(for: self)
        }
    }
}

struct WindowsRendererView: UIViewRepresentable {
    fileprivate static weak var activeView: MadeiraMetalView?
    private static var activeLayer: CAMetalLayer?
    private static var nextGeneration = 0

    static var isNativeDisplayLinked: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") != nil &&
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "macdrv_functions") != nil
    }

    static var isReadyForFrames: Bool {
        guard isNativeDisplayLinked, let view = activeView else { return false }
        return activeLayer != nil && view.window != nil && view.device != nil &&
            view.drawableSize.width >= 2 && view.drawableSize.height >= 2
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

    fileprivate static func publishLayer(_ view: MadeiraMetalView) {
        guard let layer = view.layer as? CAMetalLayer,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") else {
            return
        }
        if let activeView, activeView !== view,
           activeView.window != nil && activeView.generation > view.generation {
            return
        }

        activeView = view
        activeLayer = layer
        let callback = unsafeBitCast(symbol, to: SetMetalLayer.self)
        callback(Unmanaged.passUnretained(layer).toOpaque())

        let size = view.drawableSize
        if size.width >= 2 && size.height >= 2 && view.publishedSize != size,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "winios_display_mode_changed") {
            view.publishedSize = size
            let mode = unsafeBitCast(symbol, to: DisplayModeChanged.self)
            mode(Int32(max(1, min(size.width, 8192))), Int32(max(1, min(size.height, 8192))))
        }
    }

    fileprivate static func releaseLayer(for view: MTKView) {
        guard activeView === view else { return }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") {
            let callback = unsafeBitCast(symbol, to: SetMetalLayer.self)
            callback(nil)
        }
        activeView = nil
        activeLayer = nil
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MadeiraMetalView(frame: .zero)
        Self.nextGeneration += 1
        view.generation = Self.nextGeneration
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isOpaque = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.autoResizeDrawable = false
        view.framebufferOnly = false
        view.contentMode = .scaleAspectFit
        setenv("MVK_CONFIG_IOS_SURFACE", "1", 1)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: ()) {
        releaseLayer(for: uiView)
    }
}
