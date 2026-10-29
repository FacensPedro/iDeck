import Foundation

@main
struct GraphicsOverrideTests {
    static func main() {
        assert(GraphicsConfig.d3dOverrides(current: nil, enabled: false) == nil)
        assert(GraphicsConfig.d3dOverrides(current: nil, enabled: true) == "dxgi=n;d3d11=n;d3d10=n;d3d12=n")
        assert(GraphicsConfig.d3dOverrides(current: "dxgi=n;d3d11=n;d3d10=n;d3d12=n", enabled: false) == nil)
        assert(GraphicsConfig.d3dOverrides(current: "mmdevapi=b;dxgi=n;d3d11=n", enabled: false) == "mmdevapi=b")
        assert(GraphicsConfig.d3dOverrides(current: "mmdevapi=b;dxgi=n", enabled: true) == "mmdevapi=b;dxgi=n;d3d11=n;d3d10=n;d3d12=n")
        assert(GraphicsConfig.d3dOverrides(current: "dwrite=n,b;dxgi=n", enabled: false) == "dwrite=n,b")
        let config = GraphicsConfig()
        unsetenv("DXVK_HUD")
        config.isHUDEnabled = false
        config.useD3DMetal = true
        config.applyGraphicsEnvironment()
        assert(String(cString: getenv("DXVK_HUD")!) == "devinfo,fps")
        assert(getenv("MTL_HUD_ENABLED") == nil)
        config.isHUDEnabled = true
        config.applyGraphicsEnvironment()
        assert(String(cString: getenv("MTL_HUD_ENABLED")!) == "1")
        config.isHUDEnabled = false
        config.applyGraphicsEnvironment()
        assert(getenv("MTL_HUD_ENABLED") == nil)
        setenv("DXVK_HUD", "fps,frametimes", 1)
        config.applyGraphicsEnvironment()
        assert(String(cString: getenv("DXVK_HUD")!) == "fps,frametimes")

        assert(String(cString: getenv("WINEDLLOVERRIDES")!).contains("dxgi=n"))
        config.useD3DMetal = false
        config.applyGraphicsEnvironment()
        assert(!(getenv("WINEDLLOVERRIDES").map { String(cString: $0) } ?? "").contains("dxgi=n"))
        print("PASS: managed DXMT override settings do not leak between games")
    }
}
