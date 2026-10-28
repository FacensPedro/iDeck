import Foundation

/// Appends `value` to a ";"-separated environment variable, creating it if unset and
/// skipping entries that are already present.
func appendEnvironmentList(_ key: String, _ value: String) {
    let current = getenv(key).map { String(cString: $0) } ?? ""
    var entries = current.split(separator: ";").map(String.init)
    for entry in value.split(separator: ";").map(String.init) where !entries.contains(entry) {
        entries.append(entry)
    }
    setenv(key, entries.joined(separator: ";"), 1)
}

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
        
        let current = getenv("WINEDLLOVERRIDES").map { String(cString: $0) }
        if let overrides = Self.d3dOverrides(current: current, enabled: useD3DMetal) {
            setenv("WINEDLLOVERRIDES", overrides, 1)
        } else {
            unsetenv("WINEDLLOVERRIDES")
        }
    }
    static func d3dOverrides(current: String?, enabled: Bool) -> String? {
        let managed = Set(["dxgi=n", "d3d11=n", "d3d10=n", "d3d12=n"])
        var options = (current ?? "").split(separator: ";").map(String.init).filter {
            !managed.contains($0.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if enabled {
            options.append(contentsOf: ["dxgi=n", "d3d11=n", "d3d10=n", "d3d12=n"])
        }
        let result = options.joined(separator: ";")
        return result.isEmpty ? nil : result
    }

}
