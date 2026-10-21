import Foundation

class GraphicsConfig {
    var isHUDEnabled: Bool = false
    var useD3DMetal: Bool = false
    
    func applyGraphicsEnvironment() {
        if isHUDEnabled {
            setenv("DXVK_HUD", "1", 1)
            setenv("MTL_HUD_ENABLED", "1", 1)
        } else {
            unsetenv("DXVK_HUD")
            unsetenv("MTL_HUD_ENABLED")
        }
        
        setenv("MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE", "1", 1)
        setenv("MVK_ALLOW_METAL_FENCES", "1", 1)
        
        if useD3DMetal {
            setenv("WINEDLLOVERRIDES", String(cString: getenv("WINEDLLOVERRIDES")) + ";dxgi=n;d3d11=n;d3d10=n;d3d12=n", 1)
        } else {
            setenv("WINEDLLOVERRIDES", String(cString: getenv("WINEDLLOVERRIDES")) + ";dxgi=n;d3d11=n;d3d10=n", 1)
        }
    }
}
