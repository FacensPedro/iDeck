import Foundation
import CoreGraphics

struct WindowsGameProfile {
    var resolution = "960x540"
    var fpsLimit = "30"
    var graphicsAPI = "Automatic"
    var metalFXEnabled = false
    var avxEnabled = false
}

@main struct RuntimeConfigurationTests {
    static func main() {
        let normal = RuntimeConfiguration.settings(for: WindowsGameProfile())
        precondition(normal.resolutionWidth == 960 && normal.resolutionHeight == 540)
        precondition(normal.framesPerSecond == 30)
        for viewport in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 900, height: 700)] {
            let fitted = RuntimeConfiguration.fittedSize(content: CGSize(width: 960, height: 540), available: viewport)
            precondition(fitted.width <= viewport.width + 0.001 && fitted.height <= viewport.height + 0.001)
            precondition(abs(fitted.width / fitted.height - 16.0 / 9.0) < 0.001)
        }
        precondition(RuntimeConfiguration.fittedSize(content: .zero, available: CGSize(width: 10, height: 10)) == .zero)
        var custom = WindowsGameProfile()
        custom.resolution = "1920x1080"
        custom.fpsLimit = "60"
        let settings = RuntimeConfiguration.settings(for: custom)
        precondition(settings.resolutionWidth == 1920 && settings.framesPerSecond == 60)
        let game = CGSize(width: 1280, height: 720)
        let available = CGRect(x: 10, y: 60, width: 400, height: 300)
        let fit = RuntimeConfiguration.surfaceRect(guest: game, bounds: available, mode: .fit)
        let fill = RuntimeConfiguration.surfaceRect(guest: game, bounds: available, mode: .fill)
        let stretch = RuntimeConfiguration.surfaceRect(guest: game, bounds: available, mode: .stretch)
        let aspect = RuntimeConfiguration.surfaceRect(
            guest: game, drawable: CGSize(width: 1024, height: 768),
            bounds: available, mode: .aspect)
        precondition(abs(fit.width - 400) < 0.001 && abs(fit.height - 225) < 0.001)
        precondition(abs(fill.width - 533.333333) < 0.01 && abs(fill.height - 300) < 0.001)
        precondition(stretch == available)
        precondition(abs(aspect.width - 400) < 0.001 && abs(aspect.height - 300) < 0.001)
        for mode in RuntimeConfiguration.SurfaceMode.allCases {
            let rect = RuntimeConfiguration.surfaceRect(
                guest: game, drawable: CGSize(width: 1024, height: 768),
                bounds: available, mode: mode)
            let mapped = RuntimeConfiguration.guestPoint(
                CGPoint(x: rect.midX, y: rect.midY), guest: game,
                drawable: CGSize(width: 1024, height: 768),
                bounds: available, mode: mode)
            precondition(mapped != nil)
            precondition(abs(mapped!.x - 640) < 0.01 && abs(mapped!.y - 360) < 0.01)
            let clamped = RuntimeConfiguration.guestPoint(
                CGPoint(x: -1e6, y: -1e6), guest: game, bounds: available, mode: mode)
            precondition(clamped == .zero)
        }
        precondition(RuntimeConfiguration.SurfaceMode(saved: "legacy") == .fit)
        precondition(RuntimeConfiguration.guestPoint(.zero, guest: .zero,
                                                     bounds: available, mode: .fit) == nil)
        for window in [CGRect(x: 0, y: 0, width: 390, height: 844),
                       CGRect(x: 0, y: 0, width: 844, height: 390),
                       CGRect(x: 0, y: 0, width: 1024, height: 768)] {
            for mode in RuntimeConfiguration.SurfaceMode.allCases {
                let rect = RuntimeConfiguration.surfaceRect(guest: game, bounds: window, mode: mode)
                precondition(rect.width > 0 && rect.height > 0)
                precondition(RuntimeConfiguration.guestPoint(
                    CGPoint(x: window.midX, y: window.midY),
                    guest: game, bounds: window, mode: mode) != nil)
            }
        }
        print("Runtime configuration and resizing checks passed")
    }
}
