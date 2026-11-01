import Foundation

enum VisualCRuntimeBootstrap {
    static let downloadURL = URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!
    static let installStatus = "Installing Microsoft Visual C++..."
    static let requiredDLLs = [
        "concrt140.dll", "msvcp140.dll", "msvcp140_1.dll",
        "msvcp140_2.dll", "msvcp140_atomic_wait.dll",
        "msvcp140_codecvt_ids.dll", "vcamp140.dll", "vccorlib140.dll",
        "vcomp140.dll", "vcruntime140.dll", "vcruntime140_1.dll",
        "vcruntime140_threads.dll", "mfc140.dll", "mfc140u.dll"
    ]

    static func hasCompleteRuntime(in directory: URL) -> Bool {
        requiredDLLs.allSatisfy { name in
            let path = directory.appendingPathComponent(name)
            return path.path.withCString { ideck_vcrt_valid_pe_x64($0) != 0 }
        }
    }

    static func installed(in prefix: URL, documents: URL? = nil) -> Bool {
        if let documents,
           hasCompleteRuntime(in: documents.appendingPathComponent("vcruntime", isDirectory: true)) {
            return true
        }
        if let resources = Bundle.main.resourceURL,
           hasCompleteRuntime(in: resources.appendingPathComponent("x86_64-vcruntime", isDirectory: true)) {
            return true
        }
        return false
    }

    static func extractAndInstall(installer: URL, documents: URL,
                                  completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let stage = documents.appendingPathComponent(".vcruntime-staging-\(UUID().uuidString)", isDirectory: true)
            let live = documents.appendingPathComponent("vcruntime", isDirectory: true)
            let backup = documents.appendingPathComponent(".vcruntime-backup-\(UUID().uuidString)", isDirectory: true)
            var backedUp = false
            do {
                try fileManager.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
                defer { try? fileManager.removeItem(at: stage) }
                var output = [CChar](repeating: 0, count: 512)
                let capacity = output.count
                let result = installer.path.withCString { source in
                    stage.path.withCString { destination in
                        ideck_vcrt_extract(source, destination, &output, capacity)
                    }
                }
                guard result == 0, hasCompleteRuntime(in: stage) else {
                    let reason = String(cString: output)
                    throw NSError(domain: "iDeck.VisualC", code: Int(result),
                                  userInfo: [NSLocalizedDescriptionKey: reason.isEmpty
                                    ? "Microsoft CAB extraction failed." : reason])
                }
                if fileManager.fileExists(atPath: live.path) {
                    try fileManager.moveItem(at: live, to: backup)
                    backedUp = true
                }
                do {
                    try fileManager.moveItem(at: stage, to: live)
                    guard hasCompleteRuntime(in: live) else {
                        throw NSError(domain: "iDeck.VisualC", code: -10,
                                      userInfo: [NSLocalizedDescriptionKey: "Installed DLL verification failed."])
                    }
                    if backedUp { try? fileManager.removeItem(at: backup) }
                    DispatchQueue.main.async { completion(.success(())) }
                } catch {
                    try? fileManager.removeItem(at: live)
                    if backedUp { try? fileManager.moveItem(at: backup, to: live) }
                    throw error
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func hasPE(_ file: URL, machines: Set<UInt16> = [0x8664]) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        do {
            guard let dos = try handle.read(upToCount: 64), dos.count == 64,
                  dos[0] == 0x4D, dos[1] == 0x5A else { return false }
            let offset = UInt64(dos[0x3C]) |
                         (UInt64(dos[0x3D]) << 8) |
                         (UInt64(dos[0x3E]) << 16) |
                         (UInt64(dos[0x3F]) << 24)
            guard (64...1_048_576).contains(offset) else { return false }
            try handle.seek(toOffset: offset)
            guard let pe = try handle.read(upToCount: 6), pe.count == 6,
                  pe[0] == 0x50, pe[1] == 0x45, pe[2] == 0,
                  pe[3] == 0 else { return false }
            let machine = UInt16(pe[4]) | (UInt16(pe[5]) << 8)
            return machines.contains(machine)
        } catch {
            return false
        }
    }

    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil,
              url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "aka.ms" ||
            host == "download.microsoft.com" ||
            host == "download.visualstudio.microsoft.com"
    }

    static func download(in prefix: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let downloads = prefix.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
        let destination = downloads.appendingPathComponent("vc_redist.x64.exe")
        do {
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: request) { temporary, response, error in
            defer { session.finishTasksAndInvalidate() }
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                guard let temporary, let response = response as? HTTPURLResponse,
                      response.statusCode == 200,
                      let finalURL = response.url, isTrustedDownloadURL(finalURL) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard (100_000...150_000_000).contains(size),
                      hasPE(temporary, machines: [0x014C, 0x8664]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }
}

/// Visual C++ 2005, 2008, 2010, 2012 and 2013 (x86 and x64) and the 32-bit
/// 2015–2022 runtime, extracted from Microsoft's official redistributables
/// without running them (same CAB extraction as the x64 2015–2022 runtime).
///
/// Layout in Documents/vcruntime:
///   *.dll       x64 DLLs Madeira links into system32 for every session. The
///               x64 C runtime cores (msvcrXX/msvcpXX) stay Wine's ARM64EC
///               builtins, like vcruntime140/msvcp140 (Madeira's EC SEH
///               exemption): only MFC, ATL, OpenMP, AMP and WinRT DLLs go here.
///   x86/*.dll   32-bit DLLs linked into syswow64; the VC80/VC90 CRT and ATL
///               into the x86 side-by-side store (32-bit code has no EC path).
///   x64-sxs/    x64 VC80/VC90 ATL for the amd64 side-by-side store.
enum VisualCRuntimeLegacy {
    struct Package {
        let name: String       // "2010 x86"
        let url: URL
        let machine: Int32     // 0x014c x86, 0x8664 x64
        let dlls: [String]
        let required: String   // the package failed without it
    }

    static let x86Machine: Int32 = 0x014c
    static let x64Machine: Int32 = 0x8664
    static let installStatus = "Installing Microsoft Visual C++ 2005-2013 and 32-bit runtimes..."
    static let markerName = ".legacy-v1"

    private static let ms = "https://download.microsoft.com/download/"

    static func dlls(_ version: String, cores: Bool, extra: [String]) -> [String] {
        let crt = cores ? ["msvcr\(version).dll", "msvcp\(version).dll"] : []
        let mfc = ["mfc\(version).dll", "mfc\(version)u.dll", "mfcm\(version).dll", "mfcm\(version)u.dll"]
        return crt + mfc + extra
    }

    static let packages: [Package] = {
        var list: [Package] = []
        func add(_ year: String, _ version: String, x86: String, x64: String, extra: [String]) {
            list.append(Package(name: "\(year) x86", url: URL(string: x86)!, machine: x86Machine,
                                dlls: dlls(version, cores: true, extra: extra), required: "msvcr\(version).dll"))
            list.append(Package(name: "\(year) x64", url: URL(string: x64)!, machine: x64Machine,
                                dlls: dlls(version, cores: false, extra: extra), required: "mfc\(version).dll"))
        }
        add("2005", "80", x86: ms + "8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE",
            x64: ms + "8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE",
            extra: ["atl80.dll", "msvcm80.dll"])
        add("2008", "90", x86: ms + "5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe",
            x64: ms + "5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe",
            extra: ["atl90.dll", "msvcm90.dll"])
        add("2010", "100", x86: ms + "1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe",
            x64: ms + "1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe",
            extra: ["atl100.dll", "vcomp100.dll"])
        add("2012", "110", x86: ms + "1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe",
            x64: ms + "1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe",
            extra: ["vcomp110.dll", "vcamp110.dll", "vccorlib110.dll"])
        add("2013", "120", x86: "https://aka.ms/highdpimfc2013x86enu",
            x64: "https://aka.ms/highdpimfc2013x64enu",
            extra: ["vcomp120.dll", "vcamp120.dll", "vccorlib120.dll"])
        list.append(Package(name: "2015-2022 x86", url: URL(string: "https://aka.ms/vc14/vc_redist.x86.exe")!,
                            machine: x86Machine, dlls: VisualCRuntimeBootstrap.requiredDLLs,
                            required: "vcruntime140.dll"))
        return list
    }()

    /// Side-by-side DLLs: never linked into system32/syswow64 directly.
    static func isSideBySide(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["msvcr80", "msvcp80", "msvcm80", "msvcr90", "msvcp90", "msvcm90", "atl80", "atl90"]
            .contains { lower == $0 + ".dll" }
    }

    static func installed(documents: URL) -> Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent("vcruntime/\(markerName)").path)
    }

    /// Where an extracted DLL goes, relative to Documents/vcruntime.
    static func destination(_ name: String, machine: Int32) -> String? {
        if machine == x86Machine { return "x86/" + name }
        if isSideBySide(name) {
            // x64 msvcr80/90 cores are not extracted; only ATL is side-by-side here.
            return name.hasPrefix("atl") ? "x64-sxs/" + name : nil
        }
        return name
    }

    /// Extracts one downloaded redistributable into Documents/vcruntime.
    /// Returns the DLL names installed.
    static func extract(_ package: Package, installer: URL, documents: URL) throws -> [String] {
        let manager = FileManager.default
        let root = documents.appendingPathComponent("vcruntime", isDirectory: true)
        let stage = documents.appendingPathComponent(".vcruntime-legacy-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        var found = [Int32](repeating: 0, count: package.dlls.count)
        var message = [CChar](repeating: 0, count: 512)
        let capacity = message.count
        let names = package.dlls.map { strdup($0) }
        defer { names.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = names.map { $0.map { UnsafePointer($0) } }
        let result = installer.path.withCString { source in
            stage.path.withCString { target in
                pointers.withUnsafeBufferPointer { list in
                    ideck_vcrt_extract_set(source, target, list.baseAddress, Int32(package.dlls.count),
                                           package.machine, &found, &message, capacity)
                }
            }
        }
        guard result >= 0, let index = package.dlls.firstIndex(of: package.required), found[index] != 0 else {
            let reason = String(cString: message)
            throw NSError(domain: "iDeck.VisualC", code: Int(result), userInfo: [NSLocalizedDescriptionKey:
                "Visual C++ \(package.name): " + (reason.isEmpty ? "\(package.required) not found." : reason)])
        }
        var installed: [String] = []
        for (i, name) in package.dlls.enumerated() where found[i] != 0 {
            guard let relative = destination(name, machine: package.machine) else { continue }
            let target = root.appendingPathComponent(relative)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: target)
            try manager.moveItem(at: stage.appendingPathComponent(name), to: target)
            installed.append(relative)
        }
        return installed
    }

    /// Downloads one redistributable from Microsoft into a temporary file.
    static func download(_ package: Package) async throws -> URL {
        var request = URLRequest(url: package.url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, VisualCRuntimeBootstrap.isTrustedDownloadURL(final) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileReadUnknown)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard (100_000...150_000_000).contains(size),
              VisualCRuntimeBootstrap.hasPE(temporary, machines: [0x014C, 0x8664]) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileReadCorruptFile)
        }
        return temporary
    }

    /// Installs every package. A package that fails is reported and skipped;
    /// the marker is written once all succeeded, so failures retry next time.
    static func installAll(documents: URL, progress: @escaping (String) -> Void) async -> [String] {
        var failures: [String] = []
        for package in packages {
            if Task.isCancelled { return failures }
            progress(package.name)
            do {
                let installer = try await download(package)
                defer { try? FileManager.default.removeItem(at: installer) }
                try Task.checkCancellation()
                _ = try extract(package, installer: installer, documents: documents)
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled { return failures }
                failures.append("\(package.name): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty && !Task.isCancelled {
            let marker = documents.appendingPathComponent("vcruntime/\(markerName)")
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        return failures
    }
}
