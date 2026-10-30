import SwiftUI
import UIKit
import Metal
import QuartzCore
import Darwin

// Madeira's presenting CAMetalLayer must live outside SwiftUI's snapshot
// hierarchy. Unlike an MTKView owned by UIViewRepresentable, this raw UIKit
// host belongs directly to UIWindow and survives view replacement/rotation.
private final class MadeiraWindowMetalHost: UIView {
    static let shared = MadeiraWindowMetalHost(frame: .zero)

    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        isOpaque = true
        contentScaleFactor = 1
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // The window-specific drawable dimensions are seeded only when the
        // viewport attaches. DXMT/Winemetal owns all subsequent mode changes.
        metalLayer.drawableSize = CGSize(width: 2, height: 2)
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
    private static var drawableObservation: NSKeyValueObservation?
    private static var currentSurface: (guest: CGSize, drawable: CGSize, bounds: CGRect, mode: RuntimeConfiguration.SurfaceMode)?

    static var isNativeDisplayLinked: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "madeira_display_set_layer") != nil &&
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "macdrv_functions") != nil
    }

    static var isReadyForFrames: Bool {
        // A hosted UIView is not a usable native renderer until Madeira
        // has received the actual persistent CAMetalLayer pointer. Starting
        // Wine sooner may create its first swapchain against a null layer.
        guard isNativeDisplayLinked, layerRegistered,
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

    private typealias ScreenSize = @convention(c) (UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Void
    private typealias SetMetalLayer = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias DisplayModeChanged = @convention(c) (Int32, Int32) -> Void
    private typealias SetCompositorFrame = @convention(c) (Double, Double, Double, Double) -> Void
    private typealias SetDesktopRect = @convention(c) (Double, Double, Double, Double, Int32) -> Void
    private typealias ShowCompositor = @convention(c) (Int32) -> Int32

    private static var currentGuestSize: CGSize {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "winios_screen_size") {
            let read = unsafeBitCast(symbol, to: ScreenSize.self)
            var width: Int32 = 0
            var height: Int32 = 0
            read(&width, &height)
            if (320...7680).contains(Int(width)), (240...4320).contains(Int(height)) {
                return CGSize(width: Int(width), height: Int(height))
            }
        }
        return requestedSize ?? CGSize(width: 960, height: 540)
    }

    // Shared geometric mapping, also used by touch overlays. Returns guest
    // monitor coordinates from the physical active UIWindow's coordinate space.
    static func guestPoint(fromWindow point: CGPoint) -> CGPoint? {
        guard let surface = currentSurface else { return nil }
        return RuntimeConfiguration.guestPoint(point, guest: surface.guest,
            drawable: surface.drawable, bounds: surface.bounds, mode: surface.mode)
    }



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
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "winios_compositor_set_hidden") {
            let show = unsafeBitCast(symbol, to: ShowCompositor.self)
            _ = show(0)
        }
        let host = MadeiraWindowMetalHost.shared
        guard host.metalLayer.device != nil else { return }
        if host.superview !== window {
            host.removeFromSuperview()
            window.addSubview(host)
        }
        layoutViewport(viewport)
        // On iPhone Duo the window can migrate between the outer and inner
        // displays while the same native Wine session remains active.
        // Seed the initial drawable from the attached scene, not the global
        // main screen. Never overwrite drawableSize after native registration.
        if !layerRegistered {
            let scale = host.contentScaleFactor
            host.metalLayer.drawableSize = CGSize(
                width: max(2, (host.bounds.width * scale).rounded()),
                height: max(2, (host.bounds.height * scale).rounded()))
        }
        if !layerRegistered,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "madeira_display_set_layer") {
            let setter = unsafeBitCast(symbol, to: SetMetalLayer.self)
            setter(Unmanaged.passUnretained(host.metalLayer).toOpaque())
            layerRegistered = true
            // Follow swapchain resize without overwriting drawableSize.
            drawableObservation = host.metalLayer.observe(\.drawableSize, options: [.new]) { _, _ in
                DispatchQueue.main.async { refreshNativeDisplay() }
            }
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
        // Read scale from this scene's actual window: UIScreen.main is
        // ambiguous on the iPhone Duo's two displays and in external scenes.
        let sceneScale = window.screen.scale
        if sceneScale.isFinite && sceneScale > 0 &&
           host.contentScaleFactor != sceneScale {
            host.contentScaleFactor = sceneScale
        }
        let frame = viewport.convert(viewport.bounds, to: window)
        guard frame.width >= 2 && frame.height >= 2 else { return }
        // The raw surface sits above the SwiftUI hierarchy. Reserve the
        // session toolbar's top strip so Close, diagnostics and the optional
        // FPS overlay stay visible and accessible during gameplay.
        let toolbar = min(84.0, max(64.0, frame.height * 0.10))
        // Touchscreen controls are rendered by SwiftUI below the UIWindow
        // CAMetalLayer. Keep a real interaction band unobscured by Metal.
        let touchEnabled = getenv("IDECK_TOUCH_CONTROLS_ACTIVE").map {
            String(cString: $0) == "1"
        } ?? false
        let controlsHeight = touchEnabled ? min(190.0, max(160.0, frame.height * 0.38)) : 0
        let bounds = CGRect(x: frame.minX, y: frame.minY + toolbar,
                            width: frame.width, height: max(1, frame.height - toolbar - controlsHeight))
        let guest = currentGuestSize
        let mode = RuntimeConfiguration.SurfaceMode(
            saved: getenv("IDECK_DISPLAY_SCALING").map { String(cString: $0) } ?? "fit")
        let drawable = host.metalLayer.drawableSize
        let positioned = RuntimeConfiguration.surfaceRect(
            guest: guest, drawable: drawable, bounds: bounds, mode: mode)
        currentSurface = (guest: guest, drawable: drawable, bounds: bounds, mode: mode)
        if host.frame != positioned {
            host.frame = positioned
        }
        // The Wine compositor can initialize AFTER this SwiftUI view has
        // reached its final size. A one-time frame-change guard leaves GDI
        // windows black because no desktop rectangle is ever published.
        // This refresh is also invoked while a Windows guest is launching.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "winios_set_compositor_frame") {
            let setFrame = unsafeBitCast(symbol, to: SetCompositorFrame.self)
            setFrame(Double(frame.minX), Double(frame.minY),
                     Double(frame.width), Double(frame.height))
        }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "winios_set_desktop_rect") {
            let setDesktop = unsafeBitCast(symbol, to: SetDesktopRect.self)
            setDesktop(Double(positioned.minX - frame.minX),
                       Double(positioned.minY - frame.minY),
                       Double(positioned.width), Double(positioned.height), 1)
        }
        // Do NOT write host.metalLayer.drawableSize here. Upstream DXMT owns
        // the drawable dimensions; a second writer causes black frames.
    }

    // Re-publish native display state after Wine, its compositor and the
    // requested guest monitor are initialized. This never recreates the
    // CAMetalLayer or overwrites DXMT's live drawable dimensions.
    static func refreshNativeDisplay() {
        guard let viewport = activeViewport, viewport.window != nil else { return }
        attachViewport(viewport)
        layoutViewport(viewport)
    }

    fileprivate static func detachViewport(_ viewport: UIView) {
        guard activeViewport === viewport else { return }
        activeViewport = nil
        lastGuestSize = nil
        currentSurface = nil
        // Keep the persistent layer object alive for DXMT's cached
        // swapchain pointer, but remove its window overlay on dismissal.
        MadeiraWindowMetalHost.shared.removeFromSuperview()
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "winios_compositor_set_hidden") {
            let hide = unsafeBitCast(symbol, to: ShowCompositor.self)
            _ = hide(1)
        }
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
