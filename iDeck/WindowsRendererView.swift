import SwiftUI
import UIKit
import Metal
import QuartzCore
import Darwin

// Madeira's presenting CAMetalLayer must live outside SwiftUI's snapshot
// hierarchy. Unlike an MTKView owned by UIViewRepresentable, this raw UIKit
// host belongs directly to UIWindow and survives view replacement/rotation.
private final class MadeiraWindowMetalHost: UIView {
    static let shared = MadeiraWindowMetalHost(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        isOpaque = true
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // A nonzero seed avoids a drawable allocation race. DXMT/Winemetal
        // owns drawableSize from here on, including guest mode changes.
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }

    required init?(coder: NSCoder) { nil }
}

private final class MadeiraMetalViewport: UIView {
    var generation = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            WindowsRendererView.attachViewport(self)
        } else {
            WindowsRendererView.detachViewport(self)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        WindowsRendererView.layoutViewport(self)
    }
}

struct WindowsRendererView: UIViewRepresentable {
    fileprivate static weak var activeViewport: MadeiraMetalViewport?
    private static var nextGeneration = 0
    private static var layerRegistered = false
    private static var lastGuestSize: CGSize?

    static var isNativeDisplayLinked: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") != nil &&
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "macdrv_functions") != nil
    }

    static var isReadyForFrames: Bool {
        guard isNativeDisplayLinked,
              let view = activeViewport,
              let window = view.window else { return false }
        let host = MadeiraWindowMetalHost.shared
        return host.superview === window && host.metalLayer.device != nil &&
            host.bounds.width >= 2 && host.bounds.height >= 2
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

    fileprivate static func attachViewport(_ viewport: MadeiraMetalViewport) {
        guard isNativeDisplayLinked, let window = viewport.window else { return }
        if let previous = activeViewport, previous !== viewport,
           previous.window != nil && previous.generation > viewport.generation {
            return
        }
        if activeViewport !== viewport {
            lastGuestSize = nil
        }
        activeViewport = viewport
        let host = MadeiraWindowMetalHost.shared
        guard host.metalLayer.device != nil else { return }
        if host.superview !== window {
            host.removeFromSuperview()
            window.addSubview(host)
        }
        layoutViewport(viewport)
        if !layerRegistered,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "madeira_display_set_layer") {
            let setter = unsafeBitCast(symbol, to: SetMetalLayer.self)
            setter(Unmanaged.passUnretained(host.metalLayer).toOpaque())
            layerRegistered = true
            NSLog("[iDeck Metal] registered persistent UIWindow-hosted CAMetalLayer")
        }
        // Prime the guest monitor once per launch, never on every SwiftUI
        // layout. The native game/DXMT will handle subsequent mode changes.
        if let size = requestedSize, size != lastGuestSize,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "winios_display_mode_changed") {
            lastGuestSize = size
            let mode = unsafeBitCast(symbol, to: DisplayModeChanged.self)
            mode(Int32(size.width), Int32(size.height))
        }
    }

    fileprivate static func layoutViewport(_ viewport: MadeiraMetalViewport) {
        guard activeViewport === viewport,
              let window = viewport.window else { return }
        let host = MadeiraWindowMetalHost.shared
        guard host.superview === window else { return }
        let frame = viewport.convert(viewport.bounds, to: window)
        guard frame.width >= 2 && frame.height >= 2 else { return }
        // The raw surface sits above the SwiftUI hierarchy. Reserve the
        // session toolbar's top strip so Close, diagnostics and the optional
        // FPS overlay stay visible and accessible during gameplay.
        let toolbar = min(84.0, max(64.0, frame.height * 0.10))
        let positioned = CGRect(x: frame.minX, y: frame.minY + toolbar,
                                width: frame.width, height: max(1, frame.height - toolbar))
        if host.frame != positioned {
            host.frame = positioned
        }
        // Do NOT write host.metalLayer.drawableSize here. Upstream DXMT owns
        // the drawable dimensions; a second writer causes black frames.
    }

    fileprivate static func detachViewport(_ viewport: UIView) {
        guard activeViewport === viewport else { return }
        activeViewport = nil
        lastGuestSize = nil
        // Keep the persistent layer object alive for DXMT's cached
        // swapchain pointer, but remove its window overlay on dismissal.
        MadeiraWindowMetalHost.shared.removeFromSuperview()
    }

    func makeUIView(context: Context) -> UIView {
        let view = MadeiraMetalViewport(frame: .zero)
        Self.nextGeneration += 1
        view.generation = Self.nextGeneration
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        setenv("MVK_CONFIG_IOS_SURFACE", "1", 1)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let viewport = uiView as? MadeiraMetalViewport {
            Self.attachViewport(viewport)
            Self.layoutViewport(viewport)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        detachViewport(uiView)
    }
}
