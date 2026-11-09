import Foundation

// GOG's own client, GOG Galaxy 2.0, installed in iDeck's Wine prefix by the initial
// setup. The full offline setup is the one GOG's web installer itself fetches: its link
// comes from GOG's remote config (remote-config.gog.com, component "webinstaller"),
// so it is always the current release, downloaded from GOG's CDN. The setup is an Inno
// Setup program, run silently through Wine into C:\Program Files (x86)\GOG Galaxy.
// Nothing of it is in the IPA. Log tag: [gog-galaxy].

enum GOGGalaxyClient {
    static let remoteConfig = URL(string: "https://remote-config.gog.com/components/webinstaller?component_version=2.0.0")!
    static let relativeFolder = "Program Files (x86)/GOG Galaxy"
    static let windowsExecutable = "C:\\Program Files (x86)\\GOG Galaxy\\GalaxyClient.exe"
    static let silentArguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS /DIR=\"C:\\Program Files (x86)\\GOG Galaxy\""
    static let profileID = "gog-galaxy-setup"

    enum InstallError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    static func executable(prefix: URL) -> URL {
        prefix.appendingPathComponent("drive_c/\(relativeFolder)/GalaxyClient.exe")
    }

    static func installed(prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath: executable(prefix: prefix).path)
    }

    /// The current GOG Galaxy setup's link from GOG's remote config.
    static func setupURL() async throws -> URL {
        var request = URLRequest(url: remoteConfig)
        request.setValue(GOGAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await GOGAPI.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let windows = content["windows"] as? [String: Any],
              let link = windows["downloadLink"] as? String,
              let url = URL(string: link), url.scheme == "https",
              let host = url.host, host == "gog.com" || host.hasSuffix(".gog.com") || host.hasSuffix(".gog-statics.com") else {
            throw InstallError.message("GOG did not return a GOG Galaxy download (HTTP \(status)).")
        }
        return url
    }

    /// Downloads GOG Galaxy's setup into the prefix (C:\ProgramData\iDeck), checked as a
    /// Windows program. `progress` gets the fraction downloaded.
    static func downloadSetup(prefix: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let url = try await setupURL()
        AppLog.record("[gog-galaxy] downloading \(url.lastPathComponent)")
        let folder = prefix.appendingPathComponent("drive_c/ProgramData/iDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let delegate = GalaxySetupDownloadDelegate(progress: progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw InstallError.message("The GOG Galaxy download failed (HTTP \(status)).") }
        let handle = try FileHandle(forReadingFrom: temporary)
        let magic = try handle.read(upToCount: 2)
        try? handle.close()
        guard magic == Data([0x4d, 0x5a]) else { throw InstallError.message("The GOG Galaxy download is not a Windows program.") }
        let setup = folder.appendingPathComponent("setup_galaxy.exe")
        try? FileManager.default.removeItem(at: setup)
        try FileManager.default.moveItem(at: temporary, to: setup)
        return setup
    }

    static func removeSetup(prefix: URL) {
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent("drive_c/ProgramData/iDeck/setup_galaxy.exe"))
    }

    static var setupProfile: WindowsGameProfile {
        WindowsGameProfile(id: profileID, title: "GOG Galaxy", arguments: silentArguments)
    }

    static var launchProfile: WindowsGameProfile {
        WindowsGameProfile(id: "gog-galaxy", title: "GOG Galaxy")
    }
}

private final class GalaxySetupDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
