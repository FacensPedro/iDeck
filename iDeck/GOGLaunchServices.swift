import Foundation

// What GOG Galaxy does around a GOG game, done by iDeck the way Madeira does it
// (Madeira docs/GOG.md): iDeck does not install GOG Galaxy.
//
//  - Install script: before each start, the setRegistry values of the game's
//    goggame-<id>.script files (GOGInstallScript) are written into the prefix.
//  - Redistributables: the installers GOG lists for the build (GOGSetup), downloaded
//    into the game's folder with its files, run once per prefix before the game, from
//    a batch that then starts the game: C:\ideck-games\gog-<id>.bat, run by Wine's
//    cmd.exe. Each installer's exit code is kept, so another game that needs the same
//    one does not run it again and a failing one is not retried at every start.
//  - Galaxy game services: GOGGalaxy (127.0.0.1:9977) as before.
//
// The game's setup record is .ideck-gog.json in its folder. Log tags: [gog-script],
// [gog-setup].

struct GOGSetupRecord: Codable, Equatable {
    var language: String
    var programs: [GOGSetupProgram]
    var notes: [GOGSetupNote]

    static let fileName = ".ideck-gog.json"

    static func load(folder: URL) -> GOGSetupRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(GOGSetupRecord.self, from: data)
    }

    func save(folder: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

enum GOGLaunchServices {
    static let batchFolder = "C:\\ideck-games"

    /// After an install: what the game's first start needs.
    /// An installer whose files did not download is left out with a note.
    static func record(_ plan: GOGContentPlan, folder: URL) {
        var notes = plan.setupNotes
        let programs = plan.setupPrograms.filter { program in
            let present = FileManager.default.fileExists(atPath: folder.appendingPathComponent(program.executable).path)
            if !present {
                notes.append(GOGSetupNote(id: program.id, name: program.name, note: "Not downloaded"))
                AppLog.record("[gog-setup] \(program.id) left out: its installer did not download")
            }
            return present
        }
        GOGSetupRecord(language: plan.language, programs: programs, notes: notes).save(folder: folder)
    }

    /// The Windows path of a folder inside `drive` (drive_c).
    static func windowsPath(_ url: URL, drive: URL) -> String? {
        let root = drive.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return "C:\\" + path.dropFirst(root.count + 1).replacingOccurrences(of: "/", with: "\\")
    }

    /// Writes the install scripts' registry values. Only while Wine is stopped: the
    /// wineserver keeps the registry in memory and writes it back when it stops.
    static func applyInstallScripts(folder: URL, drive: URL) {
        guard wineserver_is_running() == 0, wine_process_is_running() == 0,
              let windows = windowsPath(folder, drive: drive) else { return }
        let language = GOGSetupRecord.load(folder: folder)?.language ?? GOGContentSystem.preferredLanguages().first ?? "en-us"
        var values: [SteamInstallValue] = []
        for file in GOGInstallScript.scripts(in: folder) {
            guard let data = try? Data(contentsOf: file), let script = GOGInstallScript.parse(data) else {
                AppLog.record("[gog-script] \(file.lastPathComponent) is not a readable install script")
                continue
            }
            let plan = script.plan(folder: windows, language: language)
            for note in plan.notes { AppLog.record("[gog-script] \(note)") }
            values += plan.values.map { value in
                let content: SteamInstallValue.Content
                switch value.data {
                case .string(let text): content = .string(text)
                case .dword(let number): content = .dword(number)
                }
                return SteamInstallValue(hive: value.root == .machine ? .machine : .user, key: value.key,
                                         name: value.name, data: content, followsInstall: value.followsInstall)
            }
        }
        guard !values.isEmpty else { return }
        do {
            let changed = try EARegistry.write(values, prefix: drive.deletingLastPathComponent())
            if changed > 0 { AppLog.record("[gog-script] \(folder.lastPathComponent): \(changed) registry values written") }
        } catch {
            AppLog.record("[gog-script] registry not written: \(error.localizedDescription)")
        }
    }

    /// The batch that runs the redistributables' installers not run yet in this prefix
    /// and then starts the game, or nil when there is nothing to run first.
    static func setupBatch(gameID: Int, folder: URL, executable: URL, arguments: String, drive: URL) -> String? {
        guard let record = GOGSetupRecord.load(folder: folder), !record.programs.isEmpty,
              let windows = windowsPath(folder, drive: drive),
              let program = windowsPath(executable, drive: drive) else { return nil }
        let lines = GOGSetup.batchLines(record.programs, folder: windows, drive: drive)
        guard !lines.isEmpty else { return nil }
        let directory = String(program[..<(program.lastIndex(of: "\\") ?? program.endIndex)])
        let start = "\"" + program + "\"" + (arguments.isEmpty ? "" : " " + arguments.replacingOccurrences(of: "%", with: "%%"))
        let text = (["@echo off"] + lines + ["cd /d \"\(directory)\"", start]).joined(separator: "\r\n") + "\r\n"
        let batch = batchFolder + "\\gog-\(gameID).bat"
        guard let url = GOGSetup.hostURL(batch, drive: drive) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            AppLog.record("[gog-setup] batch not written: \(error.localizedDescription)")
            return nil
        }
        AppLog.record("[gog-setup] game \(gameID) runs \(lines.filter { $0.hasPrefix("echo [gog-setup]") }.count) installer(s) first")
        return batch
    }
}
