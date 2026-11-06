import CryptoKit
import Foundation

// Madeira v0.2.0 Wine Gecko parity. Wine's own appwiz.cpl looks for these
// exact, hash-pinned MSI files under $HOME/.cache/wine (HOME = WINEPREFIX
// in the pinned Madeira WineProcessBridge). Do not bundle WineHQ binaries.
enum WineGeckoRuntime {
    static let version = "2.47.4"

    struct Pin: Sendable {
        let arch: String
        let sha256: String
        var name: String { "wine-gecko-\(WineGeckoRuntime.version)-\(arch).msi" }
        var url: URL {
            URL(string: "https://dl.winehq.org/wine/wine-gecko/\(WineGeckoRuntime.version)/\(name)")!
        }
    }

    // These are Madeira 0.2.0's pinned upstream WineHQ hashes. Wine's
    // appwiz.cpl validates the same files when it installs mshtml.
    static let pins: [Pin] = [
        Pin(arch: "x86", sha256: "26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6"),
        Pin(arch: "x86_64", sha256: "e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"),
    ]

    static func cache(prefix: URL) -> URL {
        prefix.appendingPathComponent(".cache/wine", isDirectory: true)
    }

    static func valid(_ url: URL, for pin: Pin) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (4096...256 * 1024 * 1024).contains(size),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                digest.update(data: chunk)
            }
        } catch { return false }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == pin.sha256
    }

    // The manager is an actor: repeated Steam / GOG library callbacks cannot
    // download or replace the same MSI concurrently.
    static func prepareInBackground(prefix: URL) {
        Task.detached(priority: .utility) {
            await WineGeckoDownloadManager.shared.prepare(prefix: prefix)
        }
    }
}

actor WineGeckoDownloadManager {
    static let shared = WineGeckoDownloadManager()
    private var checkedPrefixes = Set<String>()
    private let attemptKey = "ideck.wine-gecko-last-auto-attempt"

    func prepare(prefix: URL) async {
        let root = prefix.standardizedFileURL
        guard checkedPrefixes.insert(root.path).inserted else { return }
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }

        let fm = FileManager.default
        let cache = WineGeckoRuntime.cache(prefix: root)
        guard cache.standardizedFileURL.path == cache.resolvingSymlinksInPath().standardizedFileURL.path else {
            AppLog.record("[wine-gecko] refusing a linked Wine download cache")
            return
        }

        let missing = WineGeckoRuntime.pins.filter {
            !WineGeckoRuntime.valid(cache.appendingPathComponent($0.name), for: $0)
        }
        guard !missing.isEmpty else { return }
        // Mirrors Madeira v0.2.0's automatic, Wi-Fi-only retry cadence.
        let now = Date().timeIntervalSince1970
        guard now - UserDefaults.standard.double(forKey: attemptKey) > 86_400 else { return }
        UserDefaults.standard.set(now, forKey: attemptKey)

        do {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var directory = cache
            try directory.setResourceValues(excluded)

            let settings = URLSessionConfiguration.ephemeral
            settings.allowsExpensiveNetworkAccess = false
            settings.allowsConstrainedNetworkAccess = false
            settings.timeoutIntervalForRequest = 60
            settings.timeoutIntervalForResource = 900
            let session = URLSession(configuration: settings)
            defer { session.invalidateAndCancel() }

            for pin in missing {
                try Task.checkCancellation()
                guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
                    AppLog.record("[wine-gecko] Wine started while downloading; cache update postponed")
                    return
                }
                AppLog.record("[wine-gecko] obtaining WineHQ \(pin.name) on unmetered network")
                let (downloaded, response) = try await session.download(from: pin.url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https",
                      WineGeckoRuntime.valid(downloaded, for: pin) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let destination = cache.appendingPathComponent(pin.name)
                if WineGeckoRuntime.valid(destination, for: pin) { continue }
                guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
                    AppLog.record("[wine-gecko] Wine started; verified MSI will be downloaded on the next attempt")
                    return
                }
                if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    AppLog.record("[wine-gecko] refusing a linked Wine cache MSI: \(pin.name)")
                    continue
                }
                let staging = cache.appendingPathComponent(pin.name + ".ideck-" + UUID().uuidString)
                try fm.copyItem(at: downloaded, to: staging)
                defer { try? fm.removeItem(at: staging) }
                guard WineGeckoRuntime.valid(staging, for: pin) else { throw CocoaError(.fileReadCorruptFile) }

                let exists = fm.fileExists(atPath: destination.path)
                let backup = cache.appendingPathComponent(pin.name + ".ideck-invalid-backup")
                if exists {
                    guard !fm.fileExists(atPath: backup.path) else {
                        AppLog.record("[wine-gecko] existing invalid MSI kept; backup already exists for \(pin.name)")
                        continue
                    }
                    try fm.moveItem(at: destination, to: backup)
                }
                do {
                    try fm.moveItem(at: staging, to: destination)
                    guard WineGeckoRuntime.valid(destination, for: pin) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } catch {
                    try? fm.removeItem(at: destination)
                    if exists { try? fm.moveItem(at: backup, to: destination) }
                    throw error
                }
                AppLog.record("[wine-gecko] verified \(pin.name) is available to Wine")
            }
        } catch {
            if let network = error as? URLError,
               network.code == .notConnectedToInternet || network.networkUnavailableReason != nil {
                UserDefaults.standard.removeObject(forKey: attemptKey)
            }
            AppLog.record("[wine-gecko] automatic download incomplete: \(error.localizedDescription)")
        }
    }
}
