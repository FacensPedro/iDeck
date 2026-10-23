import Foundation

enum RuntimeConfiguration {
    struct Settings: Equatable {
        let resolutionWidth: Int
        let resolutionHeight: Int
        let framesPerSecond: Int
        let graphicsAPI: String
        let metalFXEnabled: Bool
        let avxEnabled: Bool
    }

    static func settings(for profile: WindowsGameProfile) -> Settings {
        let dimensions = profile.resolution.split(separator: "x")
        let width = dimensions.count == 2 ? Int(dimensions[0]) : nil
        let height = dimensions.count == 2 ? Int(dimensions[1]) : nil
        let fps = Int(profile.fpsLimit)
        return Settings(
            resolutionWidth: min(max(width ?? 1280, 320), 7680),
            resolutionHeight: min(max(height ?? 720, 240), 4320),
            framesPerSecond: min(max(fps ?? 60, 15), 240),
            graphicsAPI: ["Automatic", "DXMT", "D3D12"].contains(profile.graphicsAPI) ? profile.graphicsAPI : "Automatic",
            metalFXEnabled: profile.metalFXEnabled,
            avxEnabled: profile.avxEnabled
        )
    }
}
