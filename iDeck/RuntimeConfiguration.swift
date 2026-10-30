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

    enum SurfaceMode: String, CaseIterable {
        case fit, fill, stretch, aspect

        init(saved: String) {
            self = Self(rawValue: saved) ?? .fit
        }
    }

    // Match Madeira's GameSurfaceLayout. The same geometric mapping is
    // used by the host Metal layer, the Win32 compositor and touch input.
    static func surfaceRect(guest: CGSize, drawable: CGSize = .zero,
                            bounds: CGRect, mode: SurfaceMode) -> CGRect {
        guard guest.width.isFinite, guest.height.isFinite,
              guest.width > 0, guest.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        if mode == .stretch { return bounds }
        let useDrawable = mode == .aspect && drawable.width.isFinite &&
            drawable.height.isFinite && drawable.width > 0 && drawable.height > 0
        let shape = useDrawable ? drawable : guest
        let sx = bounds.width / shape.width
        let sy = bounds.height / shape.height
        let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
        let width = shape.width * scale
        let height = shape.height * scale
        return CGRect(x: bounds.minX + (bounds.width - width) / 2,
                      y: bounds.minY + (bounds.height - height) / 2,
                      width: width, height: height)
    }

    static func guestPoint(_ point: CGPoint, guest: CGSize, drawable: CGSize = .zero,
                           bounds: CGRect, mode: SurfaceMode) -> CGPoint? {
        guard guest.width.isFinite, guest.height.isFinite,
              guest.width > 0, guest.height > 0 else { return nil }
        let rect = surfaceRect(guest: guest, drawable: drawable, bounds: bounds, mode: mode)
        guard rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) * guest.width / rect.width
        let y = (point.y - rect.minY) * guest.height / rect.height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: min(max(0, x), guest.width - 1),
                       y: min(max(0, y), guest.height - 1))
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
