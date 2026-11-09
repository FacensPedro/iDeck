import Foundation
import CryptoKit

// Wine's Windows files are not in the IPA. The build moves the PE farms (x64:
// aarch64-windows, arm64ec-windows, nls, compat, vulkan; x86: i386-windows) into
// archives published as release assets and lists them in iDeckRuntimeDownloads.plist
// (scripts/split_runtime_downloads.py). The initial setup downloads them, checks each
// against its SHA-256 and unpacks them into Library/Application Support/MadeiraRuntime,
// where the native bridge reads them (scripts/apply_madeira_runtime_root.py). A build
// that still stages the farms in the bundle (development) has no list and reads the
// bundle. Log tag: [runtime].

enum MadeiraRuntime {
    struct Package: Equatable {
        let id: String
        let title: String
        let url: URL
        let sha256: String
        let bytes: Int64
    }

    enum InstallError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    /// Top-level folders the runtime archives hold; everything else stays in the bundle.
    static let downloadedFolders: Set<String> = ["aarch64-windows", "arm64ec-windows", "i386-windows",
                                                  "nls", "compat", "vulkan"]

    /// Library/Application Support/MadeiraRuntime (kept out of backups).
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MadeiraRuntime", isDirectory: true)
    }

    /// The packages this build downloads; empty when the farms are in the bundle.
    static let packages: [Package] = {
        guard let url = Bundle.main.url(forResource: "iDeckRuntimeDownloads", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["packages"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let link = item["url"] as? String, let url = URL(string: link),
                  url.scheme == "https", let sha = item["sha256"] as? String, sha.count == 64 else { return nil }
            return Package(id: id, title: item["title"] as? String ?? id, url: url, sha256: sha.lowercased(),
                           bytes: (item["bytes"] as? NSNumber)?.int64Value ?? 0)
        }
    }()

    static var downloadsRuntime: Bool { !packages.isEmpty }

    static func package(_ id: String) -> Package? { packages.first { $0.id == id } }

    private static func marker(_ id: String) -> URL { root.appendingPathComponent(".installed-\(id)") }

    /// Whether `id` is unpacked here at the SHA-256 this build lists.
    static func installed(_ id: String) -> Bool {
        guard let package = package(id) else { return !downloadsRuntime }
        let recorded = (try? String(contentsOf: marker(id), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return recorded == package.sha256
    }

    /// A package this build lists is missing or older (a new IPA brings a new runtime).
    static var needsDownload: Bool { packages.contains { !installed($0.id) } }

    /// Where the Windows files are: the downloaded runtime once it is here, else the bundle.
    static var resourceRoot: URL {
        let downloaded = root
        if FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("arm64ec-windows/ntdll.dll").path) {
            return downloaded
        }
        return Bundle.main.bundleURL
    }

    /// A runtime file by its bundle-relative path ("arm64ec-windows/ntdll.dll", "gl/…").
    static func file(_ relative: String) -> URL {
        let top = relative.split(separator: "/").first.map(String.init) ?? relative
        return (downloadedFolders.contains(top) ? resourceRoot : Bundle.main.bundleURL).appendingPathComponent(relative)
    }

    static func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: file(relative).path)
    }

    /// The Windows runtime is in the bundle or this build can download it.
    static var available: Bool {
        downloadsRuntime || FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("arm64ec-windows/ntdll.dll").path)
    }

    /// Downloads, checks and unpacks `id`. `progress` gets a status and a fraction (0…1).
    static func install(_ id: String, progress: @escaping @Sendable (String, Double) -> Void) async throws {
        guard let package = package(id) else { return }
        if installed(id) { return }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)

        AppLog.record("[runtime] downloading \(package.id) (\(package.bytes) bytes)")
        progress("Downloading \(package.title)…", 0)
        let archive = try await download(package) { fraction in progress("Downloading \(package.title)…", fraction * 0.7) }
        defer { try? fm.removeItem(at: archive) }

        progress("Checking \(package.title)…", 0.7)
        let digest = try await Task.detached(priority: .userInitiated) { try WineMonoInstaller.sha256(of: archive) }.value
        guard digest == package.sha256 else {
            AppLog.record("[runtime] \(package.id) SHA-256 mismatch")
            throw InstallError.message("\(package.title) did not match its checksum. Try again.")
        }

        let staging = root.appendingPathComponent(".staging-\(package.id)", isDirectory: true)
        try? fm.removeItem(at: staging)
        progress("Installing \(package.title)…", 0.75)
        let total = max(package.bytes * 3, 1)
        try await Task.detached(priority: .userInitiated) {
            try WineMonoInstaller.unpack(tarXZ: archive, into: staging, map: MadeiraRuntime.archivePath) { read in
                progress("Installing \(package.title)…", 0.75 + 0.25 * min(Double(read) / Double(total), 1))
            }
        }.value
        defer { try? fm.removeItem(at: staging) }

        // Swap each top-level folder in; the marker is written last.
        try? fm.removeItem(at: marker(id))
        for name in try fm.contentsOfDirectory(atPath: staging.path) where downloadedFolders.contains(name) {
            let target = root.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: staging.appendingPathComponent(name), to: target)
        }
        try package.sha256.write(to: marker(id), atomically: true, encoding: .utf8)
        AppLog.record("[runtime] \(package.id) installed")
        progress("\(package.title) installed.", 1)
    }

    /// A tar entry's path under the runtime folder, or nil to skip it: relative, no
    /// "." or "..", inside one of the runtime folders.
    static func archivePath(_ entry: String) -> String? {
        var parts = entry.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.first == "." { parts.removeFirst() }
        guard !entry.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains("."),
              downloadedFolders.contains(parts[0]) else { return nil }
        return parts.joined(separator: "/")
    }

    private static func download(_ package: Package, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = RuntimeDownloadDelegate(expected: package.bytes, progress: progress)
        var attempt = 0
        var resume: Data?
        while true {
            do {
                let (file, response): (URL, URLResponse)
                if let resume {
                    (file, response) = try await URLSession.shared.download(resumeFrom: resume, delegate: delegate)
                } else {
                    (file, response) = try await URLSession.shared.download(from: package.url, delegate: delegate)
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw InstallError.message("The runtime download failed (HTTP \(status)).") }
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(package.id)-\(UUID().uuidString).tar.xz")
                try FileManager.default.moveItem(at: file, to: kept)
                return kept
            } catch let error as URLError where attempt < 5 && [.networkConnectionLost, .timedOut,
                                                                .notConnectedToInternet, .cannotConnectToHost].contains(error.code) {
                attempt += 1
                resume = error.downloadTaskResumeData ?? resume
                AppLog.record("[runtime] download of \(package.id) interrupted (\(error.code.rawValue)); retry \(attempt)/5")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }
}

private final class RuntimeDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let progress: @Sendable (Double) -> Void
    init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
