import Foundation

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
        print("Runtime configuration and resizing checks passed")
    }
}
