import SwiftUI
import UIKit

/// Store covers and banners. They come from their own session with a disk cache,
/// a memory cache and interactive priority, so they appear at once even while a
/// download fills the network (SwiftUI's AsyncImage uses the shared session, no
/// lasting cache and default priority, and waited behind EA's download ranges).
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 96 << 20
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20, directory: nil)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.networkServiceType = .responsiveData
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func image(_ url: URL) async throws -> UIImage {
        if let image = cached(url) { return image }
        var request = URLRequest(url: url)
        request.networkServiceType = .responsiveData
        let (data, response) = try await session.data(for: request, delegate: HighPriority.shared)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        // Decoded once here, not on the main thread while scrolling.
        let ready = image.preparingForDisplay() ?? image
        memory.setObject(ready, forKey: url as NSURL, cost: data.count)
        return ready
    }

    private final class HighPriority: NSObject, URLSessionTaskDelegate {
        static let shared = HighPriority()
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            task.priority = URLSessionTask.highPriority
        }
    }
}

/// An image from ArtworkLoader: `content` once loaded, `placeholder` until then,
/// `failed` when it cannot be loaded.
struct ArtworkImage<Content: View, Placeholder: View>: View {
    let url: URL
    let failed: () -> Void
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL, failed: @escaping () -> Void = {},
         @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.failed = failed
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: ArtworkLoader.shared.cached(url))
    }

    var body: some View {
        Group {
            if let image { content(Image(uiImage: image)) } else { placeholder() }
        }
        .task(id: url) {
            guard image == nil else { return }
            do { image = try await ArtworkLoader.shared.image(url) } catch { if !Task.isCancelled { failed() } }
        }
    }
}
