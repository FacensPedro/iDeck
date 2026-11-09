import Foundation

// GOG's own client, GOG Galaxy 2.0, installed in iDeck's Wine prefix by the initial
// setup. The full offline setup is the one GOG's web installer itself fetches: its link
// comes from GOG's remote config (remote-config.gog.com, component "webinstaller"),
// so it is always the current release, downloaded from GOG's CDN. The setup is an Inno
// Setup program, run silently through Wine into C:\Program Files (x86)\GOG Galaxy.
// Nothing of it is in the IPA. Log tag: [gog-galaxy].

enum GOGGalaxyApp {
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
    /// `progress` gets the bytes downloaded and the expected total (0 when unknown).
    /// A complete setup left by an earlier attempt is used again.
    static func downloadSetup(prefix: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let folder = prefix.appendingPathComponent("drive_c/ProgramData/iDeck", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let setup = folder.appendingPathComponent("setup_galaxy.exe")
        if isWindowsProgram(setup) {
            AppLog.record("[gog-galaxy] using the setup downloaded earlier")
            return setup
        }
        let url = try await setupURL()
        AppLog.record("[gog-galaxy] downloading \(url.lastPathComponent)")
        var request = URLRequest(url: url)
        request.setValue(GOGAPI.userAgent, forHTTPHeaderField: "User-Agent")
        var attempt = 0
        var resume: Data?
        while true {
            do {
                let (temporary, response) = try await ObservedDownload.run(request, resumeData: resume, progress: progress)
                let status = response.statusCode
                if (status == 429 || (500...599).contains(status)) && attempt < 6 {
                    try? FileManager.default.removeItem(at: temporary)
                    attempt += 1
                    resume = nil
                    AppLog.record("[gog-galaxy] download got HTTP \(status); retry \(attempt)/6")
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                guard status == 200 else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw InstallError.message("The GOG Galaxy download failed (HTTP \(status)).")
                }
                guard isWindowsProgram(temporary) else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw InstallError.message("The GOG Galaxy download is not a Windows program.")
                }
                try? FileManager.default.removeItem(at: setup)
                try FileManager.default.moveItem(at: temporary, to: setup)
                AppLog.record("[gog-galaxy] setup downloaded")
                return setup
            } catch let failure as ObservedDownload.Failure {
                guard let error = failure.error as? URLError, error.code != .cancelled, attempt < 6 else { throw failure.error }
                attempt += 1
                resume = failure.resumeData ?? resume
                AppLog.record("[gog-galaxy] download interrupted (\(error.code.rawValue)); retry \(attempt)/6")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
    }

    private static func isWindowsProgram(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size > 1_000_000 && (try? handle.read(upToCount: 2)) == Data([0x4d, 0x5a])
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
