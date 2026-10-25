import Foundation
import CoreGraphics

enum RuntimeConfiguration {
    static func fittedSize(content: CGSize, available: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0, available.width > 0, available.height > 0,
              content.width.isFinite, content.height.isFinite,
              available.width.isFinite, available.height.isFinite else { return .zero }
        let scale = min(available.width / content.width, available.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }

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
            resolutionWidth: min(max(width ?? 960, 320), 7680),
            resolutionHeight: min(max(height ?? 540, 240), 4320),
            framesPerSecond: min(max(fps ?? 30, 15), 240),
            graphicsAPI: ["Automatic", "DXMT", "D3D12"].contains(profile.graphicsAPI) ? profile.graphicsAPI : "Automatic",
            metalFXEnabled: profile.metalFXEnabled,
            avxEnabled: profile.avxEnabled
        )
    }
}
