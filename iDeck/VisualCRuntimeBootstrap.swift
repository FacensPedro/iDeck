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
