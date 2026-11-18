import Foundation

// One way to run any Windows program or installer in iDeck's Wine prefix.
//
// Wine's own DLLs are always there (the downloaded runtime). Everything else is
// installed only when a program needs it: before it starts, its PE header is read
// (machine, imported and delay-loaded DLLs, CLR header) and the matching Microsoft
// Visual C++ runtime (by version and architecture) or Wine Mono (.NET Framework) is
// installed first. Installers are recognised by their technology (Windows Installer
// .msi, Inno Setup, NSIS, InstallShield, WiX Burn, 7-Zip SFX, Squirrel) and started
// the way that technology expects: an .msi through msiexec, the others with their own
// switches (no reboot; silent only when asked). Log tag: [installer].

// MARK: - PE

struct WindowsPEInfo: Equatable {
    var machine: UInt16
    var imports: Set<String>          // lowercased DLL names, imports + delay imports
    var isDotNet: Bool                // has a CLR (COM descriptor) header
    var sections: [String]
    var overlayOffset: Int            // end of the last section's raw data

    var is32Bit: Bool { machine == 0x014c }

    /// Reads at most `limit` bytes of `url`.
    static func read(_ url: URL, limit: Int = 64 << 20) -> WindowsPEInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 64 else { return nil }
        guard head[0] == 0x4d, head[1] == 0x5a else { return nil }
        let peOffset = Int(head.u32(0x3c))
        guard peOffset > 0, peOffset < 1 << 20 else { return nil }
        // The headers and the import tables: read the file up to the limit once.
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.read(upToCount: limit), data.count > peOffset + 24,
              data.u32(peOffset) == 0x0000_4550 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> WindowsPEInfo? {
        guard data.count > 0x40 else { return nil }
        let pe = Int(data.u32(0x3c))
        guard pe + 24 <= data.count, data.u32(pe) == 0x0000_4550 else { return nil }
        let machine = data.u16(pe + 4)
        let sectionCount = Int(data.u16(pe + 6))
        let optionalSize = Int(data.u16(pe + 20))
        let optional = pe + 24
        guard optional + optionalSize <= data.count, optionalSize >= 2 else { return nil }
        let magic = data.u16(optional)
        let directories: Int
        switch magic {
        case 0x10b: directories = optional + 96      // PE32
        case 0x20b: directories = optional + 112     // PE32+
        default: return nil
        }
        guard directories <= optional + optionalSize else { return nil }
        let directoryCount = min(Int(data.u32(directories - 4)), (optional + optionalSize - directories) / 8)
        let imageBase32 = magic == 0x10b ? Int(data.u32(optional + 28)) : 0
        func directory(_ index: Int) -> (rva: Int, size: Int) {
            guard index < directoryCount, directories + index * 8 + 8 <= data.count else { return (0, 0) }
            return (Int(data.u32(directories + index * 8)), Int(data.u32(directories + index * 8 + 4)))
        }

        struct Section { let name: String; let rva: Int; let virtualSize: Int; let raw: Int; let rawSize: Int }
        var sections: [Section] = []
        var table = optional + optionalSize
        var overlay = 0
        for _ in 0..<min(sectionCount, 96) {
            guard table + 40 <= data.count else { break }
            let nameBytes = data[(data.startIndex + table)..<(data.startIndex + table + 8)].prefix { $0 != 0 }
            let section = Section(name: String(decoding: nameBytes, as: UTF8.self),
                                  rva: Int(data.u32(table + 12)), virtualSize: Int(data.u32(table + 8)),
                                  raw: Int(data.u32(table + 20)), rawSize: Int(data.u32(table + 16)))
            sections.append(section)
            overlay = max(overlay, section.raw + section.rawSize)
            table += 40
        }
        func offset(_ rva: Int) -> Int? {
            for s in sections where rva >= s.rva && rva < s.rva + max(s.virtualSize, s.rawSize) {
                let value = s.raw + (rva - s.rva)
                return value < data.count ? value : nil
            }
            return nil
        }
        func cString(_ rva: Int) -> String? {
            guard let start = offset(rva) else { return nil }
            var end = start
            while end < data.count, end - start < 260, data[data.startIndex + end] != 0 { end += 1 }
            return String(decoding: data[(data.startIndex + start)..<(data.startIndex + end)], as: UTF8.self).lowercased()
        }

        var imports = Set<String>()
        // Import directory (1): 20-byte descriptors, name RVA at +12.
        let importDir = directory(1)
        if importDir.rva != 0, var at = offset(importDir.rva) {
            for _ in 0..<512 {
                guard at + 20 <= data.count else { break }
                let nameRVA = Int(data.u32(at + 12))
                if nameRVA == 0 && data.u32(at) == 0 { break }
                if let name = cString(nameRVA), !name.isEmpty { imports.insert(name) }
                at += 20
            }
        }
        // Delay-load directory (13): 32-byte descriptors, name RVA at +4.
        let delayDir = directory(13)
        if delayDir.rva != 0, var at = offset(delayDir.rva) {
            for _ in 0..<512 {
                guard at + 32 <= data.count else { break }
                let nameRVA = Int(data.u32(at + 4))
                if nameRVA == 0 { break }
                // Older PE32 delay descriptors store a VA instead of an RVA.
                let isVA = data.u32(at) & 1 == 0 && magic == 0x10b
                let rva = isVA ? nameRVA - imageBase32 : nameRVA
                if rva > 0, let name = cString(rva), !name.isEmpty { imports.insert(name) }
                at += 32
            }
        }
        let clr = directory(14)
        return WindowsPEInfo(machine: machine, imports: imports, isDotNet: clr.rva != 0 && clr.size != 0,
                             sections: sections.map(\.name), overlayOffset: overlay)
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        guard at + 2 <= count else { return 0 }
        return UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32 {
        guard at + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + at + $1]) << (8 * $1) }
    }
}

// MARK: - Installer technology

enum WindowsInstallerKind: String, Equatable, CaseIterable {
    case msi = "Windows Installer (MSI)"
    case innoSetup = "Inno Setup"
    case nsis = "NSIS"
    case installShield = "InstallShield"
    case wixBurn = "WiX Burn"
    case sevenZipSFX = "7-Zip self-extracting archive"
    case squirrel = "Squirrel"

    /// The switches the technology takes. Interactive installs only turn off reboots
    /// (and Inno's "This will install..." prompt); silent installs show no windows.
    func arguments(silent: Bool) -> String {
        switch self {
        case .msi: return silent ? "/qn /norestart" : "/norestart"
        case .innoSetup: return silent ? "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" : "/SP- /NORESTART"
        case .nsis: return silent ? "/S" : ""
        case .installShield: return silent ? "/s /v\"/qn /norestart\"" : ""
        case .wixBurn: return silent ? "/quiet /norestart" : "/norestart"
        case .sevenZipSFX: return silent ? "-y" : ""
        case .squirrel: return silent ? "--silent" : ""
        }
    }

    /// What `url` is: by the Windows Installer (OLE compound file) header for .msi,
    /// otherwise by the markers each technology writes into its setup program.
    static func detect(_ url: URL, pe: WindowsPEInfo?) -> WindowsInstallerKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        if head == Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) { return .msi }
        guard let pe else { return nil }
        if pe.sections.contains(".wixburn") { return .wixBurn }
        // Markers sit in the resources (Inno, InstallShield, Squirrel) or right after
        // the image (the NSIS and 7-Zip payloads); scan the start and the overlay.
        try? handle.seek(toOffset: 0)
        var sample = (try? handle.read(upToCount: 8 << 20)) ?? Data()
        if pe.overlayOffset > sample.count {
            try? handle.seek(toOffset: UInt64(pe.overlayOffset))
            sample.append((try? handle.read(upToCount: 1 << 20)) ?? Data())
        }
        func has(_ marker: String) -> Bool { sample.range(of: Data(marker.utf8)) != nil }
        func hasWide(_ marker: String) -> Bool {
            sample.range(of: Data(marker.utf8.flatMap { [$0, 0] })) != nil
        }
        if has("Inno Setup Setup Data") || has("Inno Setup Messages") || hasWide("Inno Setup") { return .innoSetup }
        if has("NullsoftInst") || has("Nullsoft.NSIS") { return .nsis }
        if has("InstallShield") || hasWide("InstallShield") { return .installShield }
        if sample.range(of: Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) != nil && (has("7-Zip") || hasWide("7-Zip")) {
            return .sevenZipSFX
        }
        if has("SquirrelSetup") || hasWide("Squirrel") { return .squirrel }
        return nil
    }
}

// MARK: - Requirements

struct WindowsRequirements: Equatable {
    /// Visual C++ packages by VisualCRuntimeLegacy name ("2010 x86", "2015-2022 x86").
    var visualCPackages: Set<String> = []
    /// The x64 Visual C++ 2015-2022 runtime (VisualCRuntimeBootstrap).
    var visualC2015x64 = false
    var dotNet = false

    var isEmpty: Bool { visualCPackages.isEmpty && !visualC2015x64 && !dotNet }

    private static let versions: [(String, String)] = [("80", "2005"), ("90", "2008"), ("100", "2010"),
                                                       ("110", "2012"), ("120", "2013")]

    /// What a program's imports call for.
    static func of(_ pe: WindowsPEInfo) -> WindowsRequirements {
        var result = WindowsRequirements()
        let arch = pe.is32Bit ? "x86" : "x64"
        for (version, year) in versions {
            let names = ["msvcr\(version).dll", "msvcp\(version).dll", "mfc\(version).dll", "mfc\(version)u.dll",
                         "atl\(version).dll", "vcomp\(version).dll", "msvcm\(version).dll"]
            if names.contains(where: pe.imports.contains) { result.visualCPackages.insert("\(year) \(arch)") }
        }
        let modern = pe.imports.contains {
            $0.hasPrefix("vcruntime140") || $0.hasPrefix("msvcp140") || $0 == "concrt140.dll" || $0 == "vcomp140.dll"
                || $0 == "mfc140.dll" || $0 == "mfc140u.dll" || $0 == "vcamp140.dll" || $0 == "vccorlib140.dll"
        }
        if modern {
            if pe.is32Bit { result.visualCPackages.insert("2015-2022 x86") } else { result.visualC2015x64 = true }
        }
        result.dotNet = pe.isDotNet || pe.imports.contains("mscoree.dll")
        return result
    }
}

// MARK: - Plan and on-demand install

enum WindowsInstallerEnvironment {
    struct Plan: Equatable {
        var executable: URL                  // what Wine starts
        var arguments: String                // the technology's switches, before the profile's own
        var kind: WindowsInstallerKind?
        var requirements: WindowsRequirements
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// The Windows path of a file inside the prefix's drive_c.
    static func windowsPath(_ file: URL, prefix: URL) -> String? {
        WindowsDrivePath.relative(file, drive: prefix.appendingPathComponent("drive_c"))
    }

    static func plan(for file: URL, prefix: URL, silent: Bool = false, detectInstaller: Bool = true) -> Plan? {
        let pe = WindowsPEInfo.read(file)
        let kind = detectInstaller || file.pathExtension.lowercased() == "msi" ? WindowsInstallerKind.detect(file, pe: pe) : nil
        if kind == .msi {
            guard let path = windowsPath(file, prefix: prefix) else { return nil }
            let msiexec = prefix.appendingPathComponent("drive_c/windows/system32/msiexec.exe")
            return Plan(executable: msiexec, arguments: "/i \"\(path)\" " + WindowsInstallerKind.msi.arguments(silent: silent),
                        kind: .msi, requirements: WindowsRequirements())
        }
        guard let pe else { return nil }
        return Plan(executable: file, arguments: kind?.arguments(silent: silent) ?? "", kind: kind,
                    requirements: WindowsRequirements.of(pe))
    }

    /// What of `requirements` is not installed yet.
    @MainActor static func missing(_ requirements: WindowsRequirements) -> WindowsRequirements {
        var result = WindowsRequirements()
        let root = documents.appendingPathComponent("vcruntime", isDirectory: true)
        for name in requirements.visualCPackages {
            guard let package = VisualCRuntimeLegacy.packages.first(where: { $0.name == name }),
                  let relative = VisualCRuntimeLegacy.destination(package.required, machine: package.machine) else { continue }
            let installedHere = FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
            if !installedHere && !VisualCRuntimeLegacy.installed(documents: documents) { result.visualCPackages.insert(name) }
        }
        if requirements.visualC2015x64,
           !VisualCRuntimeBootstrap.installed(in: MadeiraDock.prefix, documents: documents) {
            result.visualC2015x64 = true
        }
        if requirements.dotNet && !WineMonoModel.available { result.dotNet = true }
        return result
    }

    /// Installs what `requirements` lists and is missing. Returns the failures.
    @MainActor static func install(_ requirements: WindowsRequirements,
                                   progress: @escaping @MainActor (String) -> Void) async -> [String] {
        let needed = missing(requirements)
        var failures: [String] = []
        if needed.visualC2015x64 {
            progress("Installing Visual C++ 2015-2022 x64…")
            AppLog.record("[installer] installing Visual C++ 2015-2022 x64")
            if !VisualCRuntimeBootstrap.installBundled(documents: documents) {
                if let failure = await downloadVisualC2015x64() { failures.append(failure) }
            }
        }
        for package in VisualCRuntimeLegacy.packages where needed.visualCPackages.contains(package.name) {
            progress("Installing Visual C++ \(package.name)…")
            AppLog.record("[installer] installing Visual C++ \(package.name)")
            do {
                let installer = try await VisualCRuntimeLegacy.download(package)
                defer { try? FileManager.default.removeItem(at: installer) }
                _ = try VisualCRuntimeLegacy.extract(package, installer: installer, documents: documents)
            } catch {
                failures.append("Visual C++ \(package.name): \(error.localizedDescription)")
            }
        }
        if needed.dotNet {
            progress("Installing .NET support (Wine Mono)…")
            AppLog.record("[installer] installing Wine Mono")
            let mono = WineMonoModel.shared
            mono.install()
            while mono.busy {
                progress(mono.status)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !WineMonoModel.available { failures.append(mono.error ?? "Wine Mono was not installed.") }
        }
        for failure in failures { AppLog.record("[installer] \(failure)") }
        return failures
    }

    private static func downloadVisualC2015x64() async -> String? {
        await withCheckedContinuation { continuation in
            VisualCRuntimeBootstrap.download(in: MadeiraDock.prefix) { result in
                switch result {
                case .failure(let error):
                    continuation.resume(returning: error.localizedDescription)
                case .success(let installer):
                    VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: documents) { outcome in
                        try? FileManager.default.removeItem(at: installer)
                        if case .failure(let error) = outcome {
                            continuation.resume(returning: error.localizedDescription)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Microsoft D3DX 9 and HLSL compiler

/// Microsoft's own D3DX 9 libraries and HLSL compilers (d3dx9_24-43, d3dcompiler_33-43),
/// from Microsoft's DirectX End-User Runtime (June 2010), for a game whose shaders
/// Wine's D3DX could not compile: such a game writes ShaderErrors\CompileError*.hlsl
/// and then crashes on the shader it never got (BioShock). Only those games get them:
/// the DLLs go next to the game's program, and a per-program DLL override in the
/// prefix (AppDefaults) makes Wine load them instead of its own. Log tag: [d3dx].
enum NativeD3DX {
    static let redistURL = URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!
    static let modules: [String] = (24...43).map { "d3dx9_\($0)" } + (33...43).map { "d3dcompiler_\($0)" }
    static let executablesKey = "d3dx.native.executables"
    static let marker = ".ideck-native-d3dx"

    /// Programs a session found failing to compile its shaders; BioShock's always.
    static func wanted(_ executable: URL) -> Bool {
        let set = UserDefaults.standard.stringArray(forKey: executablesKey) ?? []
        return set.contains(executable.path) || executable.path.lowercased().contains("bioshock")
    }

    static func noteShaderFailure(_ executable: URL) {
        var set = UserDefaults.standard.stringArray(forKey: executablesKey) ?? []
        guard !set.contains(executable.path) else { return }
        set.append(executable.path)
        UserDefaults.standard.set(set, forKey: executablesKey)
        AppLog.record("[d3dx] \(executable.lastPathComponent) failed to compile a shader with Wine's D3DX: Microsoft's D3DX is used for it from its next start")
    }

    static func cache(machine: UInt16) -> URL {
        WindowsInstallerEnvironment.documents.appendingPathComponent("directx/" + (machine == 0x014c ? "x86" : "x64"), isDirectory: true)
    }

    static func installed(for executable: URL) -> Bool {
        FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent(marker).path)
    }

    /// Downloads the runtime once and keeps the DLLs of both architectures.
    static func prepareCache() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cache(machine: 0x014c).appendingPathComponent(marker).path),
           fm.fileExists(atPath: cache(machine: 0x8664).appendingPathComponent(marker).path) { return }
        var request = URLRequest(url: redistURL)
        request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? fm.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, VisualCRuntimeBootstrap.isTrustedDownloadURL(final) else { throw CocoaError(.fileReadUnknown) }
        let size = (try fm.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard (50_000_000...150_000_000).contains(size), VisualCRuntimeBootstrap.hasPE(temporary, machines: [0x014C]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Reading about 150 CABs takes a while: off the main actor.
        let installer = temporary
        try await Task.detached(priority: .userInitiated) {
            for machine: UInt16 in [0x014c, 0x8664] { try extract(installer, machine: machine) }
        }.value
    }

    /// The runtime's DLLs of one architecture into its cache folder.
    static func extract(_ installer: URL, machine: UInt16) throws {
        let fm = FileManager.default
        let folder = cache(machine: machine)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = modules.map { $0 + ".dll" }
        var found = [Int32](repeating: 0, count: names.count)
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let copies = names.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } }
        let count = installer.path.withCString { source in
            folder.path.withCString { target in
                pointers.withUnsafeBufferPointer { list in
                    ideck_vcrt_extract_set(source, target, list.baseAddress, Int32(names.count), Int32(machine),
                                           &found, &message, capacity)
                }
            }
        }
        let text = String(cString: message)
        AppLog.record("[d3dx] \(machine == 0x014c ? "x86" : "x64"): \(count) of \(names.count) DLLs (\(text))")
        guard count > 0 else { throw NSError(domain: "iDeck.d3dx", code: Int(count), userInfo: [NSLocalizedDescriptionKey: text]) }
        fm.createFile(atPath: folder.appendingPathComponent(marker).path, contents: Data())
    }

    /// Puts the DLLs next to the program and tells Wine to prefer them for it.
    static func provide(for executable: URL, machine: UInt16, prefix: URL) async throws {
        try await prepareCache()
        let fm = FileManager.default
        let source = cache(machine: machine), folder = executable.deletingLastPathComponent()
        var copied = 0
        for module in modules {
            let from = source.appendingPathComponent(module + ".dll"), to = folder.appendingPathComponent(module + ".dll")
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            try fm.copyItem(at: from, to: to)
            copied += 1
        }
        guard wine_process_is_running() == 0, wineserver_is_running() == 0 else {
            throw NSError(domain: "iDeck.d3dx", code: 1, userInfo: [NSLocalizedDescriptionKey: "a Windows session is still running"])
        }
        let key = "Software\\Wine\\AppDefaults\\" + executable.lastPathComponent + "\\DllOverrides"
        let values = modules.map { SteamInstallValue(hive: .user, key: key, name: $0, data: .string("native,builtin"), followsInstall: true) }
        try EARegistry.write(values, prefix: prefix)
        fm.createFile(atPath: folder.appendingPathComponent(marker).path, contents: Data())
        AppLog.record("[d3dx] \(executable.lastPathComponent): \(copied) Microsoft DLLs placed, Wine prefers them for this program")
    }
}
