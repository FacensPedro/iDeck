import Foundation

/// Ubisoft Connect games on iDeck. There is no open replacement for Ubisoft
/// Connect (EA has one, which iDeck uses through Madeira's EA support), and
/// Ubisoft's games ask its client for their licence. So:
///
/// - The official Ubisoft Connect installer is downloaded from Ubisoft
///   (`installerURL`) and run under Wine from Settings › Ubisoft Connect.
/// - iRelay copies a game already installed by Ubisoft Connect on the PC into
///   `installRoot` and records it (`POST /finish`, store "ubisoft").
/// - iDeck writes the install record Ubisoft Connect reads
///   (HKLM\Software\Ubisoft\Launcher\Installs\<id> InstallDir) and starts the game
///   through the client: `UbisoftConnect.exe uplay://launch/<id>/0`.
///
/// Without Ubisoft Connect installed, the game's own executable is started
/// directly (`gameExecutable`); nothing asks for the launcher first.
struct UbisoftInstalledGame: Codable, Sendable, Equatable, Identifiable {
    var id: String          // Ubisoft's install id (the registry key name)
    var title: String
    var folder: String      // relative to drive_c, forward slashes
    var installBytes: Int64
}

@MainActor final class UbisoftLibrary: ObservableObject {
    static let shared = UbisoftLibrary()
    static let installRoot = "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games"
    static let client = "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe"
    static let installer = "WindowsDownloads/Launchers/Ubisoft/UbisoftConnectInstaller.exe"
    /// Ubisoft's own download address for the Ubisoft Connect installer.
    static let installerURL = URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!

    @Published private(set) var installed: [String: UbisoftInstalledGame] = [:]

    private static var recordURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDeck/ubisoft-installed.json")
    }

    private init() { reload() }

    static var clientInstalled: Bool {
        FileManager.default.fileExists(atPath: EpicLibrary.drive.appendingPathComponent(client).path)
    }

    /// Names that are never the game itself.
    private static let notTheGame = ["unins", "setup", "install", "crash", "report", "redist", "vcredist", "dxsetup",
                                     "directx", "dotnet", "ubisoftconnect", "uplay", "upc", "eac", "easyanticheat",
                                     "battleye", "be_service", "launcherpatcher", "touchup", "cleanup"]

    /// The game's own executable: the largest .exe in its folder (three levels
    /// at most) that is not an installer, crash reporter or launcher.
    static func gameExecutable(_ game: UbisoftInstalledGame) -> URL? {
        let root = EpicLibrary.drive.appendingPathComponent(game.folder, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, size: Int)?
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let name = url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
            if notTheGame.contains(where: { name.contains($0) }) { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            if best == nil || size > best!.size { best = (url, size) }
        }
        return best?.url
    }

    static var installerDownloaded: Bool {
        FileManager.default.fileExists(atPath: EpicLibrary.drive.appendingPathComponent(installer).path)
    }

    func reload() {
        guard let data = try? Data(contentsOf: Self.recordURL),
              let list = try? JSONDecoder().decode([UbisoftInstalledGame].self, from: data) else { return }
        installed = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            .filter { FileManager.default.fileExists(atPath: EpicLibrary.drive.appendingPathComponent($0.value.folder).path) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(installed.values)).write(to: Self.recordURL, options: .atomic)
    }

    /// A game iRelay finished copying.
    func register(_ game: UbisoftInstalledGame) {
        installed[game.id] = game
        save()
        Self.writeRegistry(game)
        AppLog.record("[ubisoft] installed from the PC: \(game.title) id=\(game.id)")
    }

    func uninstall(_ id: String) {
        guard let game = installed[id] else { return }
        if game.folder.hasPrefix(Self.installRoot + "/") {
            try? FileManager.default.removeItem(at: EpicLibrary.drive.appendingPathComponent(game.folder, isDirectory: true))
        }
        installed[id] = nil
        save()
    }

    /// The install record Ubisoft Connect reads. Only while no session runs.
    nonisolated static func writeRegistry(_ game: UbisoftInstalledGame) {
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else { return }
        let path = "C:\\" + game.folder.replacingOccurrences(of: "/", with: "\\") + "\\"
        let value = SteamInstallValue(hive: .machine, key: "Software\\Ubisoft\\Launcher\\Installs\\" + game.id,
                                      name: "InstallDir", data: .string(path.replacingOccurrences(of: "\\", with: "/")),
                                      followsInstall: true)
        do {
            try EARegistry.write([value], prefix: MadeiraDock.prefix)
        } catch {
            AppLog.record("[ubisoft] registry write failed: \(error.localizedDescription)")
        }
    }

    /// Downloads the official installer from Ubisoft into the launchers folder.
    static func downloadInstaller() async throws {
        let (temporary, response) = try await URLSession.shared.download(from: installerURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host?.hasSuffix(".ubi.com") == true else {
            throw URLError(.badServerResponse)
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        let magic = try handle.read(upToCount: 2)
        try handle.close()
        guard magic == Data([0x4d, 0x5a]) else { throw URLError(.cannotDecodeContentData) }
        let target = EpicLibrary.drive.appendingPathComponent(installer)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        AppLog.record("[ubisoft] Ubisoft Connect installer downloaded from Ubisoft")
    }
}
