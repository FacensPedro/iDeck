import Foundation

enum VisualCRuntimeBootstrap {
    static let downloadURL = URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!
    static let installStatus = "Installing Microsoft Visual C++..."
    private static let markerName = ".ideck-vcredist-v14-installed"
    private static let requiredDLLs = ["vcruntime140.dll", "msvcp140.dll"]

    static func installed(in prefix: URL, documents: URL? = nil) -> Bool {
        let paths = [
            prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true),
            prefix.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        ]
        if let documents {
            let custom = documents.appendingPathComponent("vcruntime", isDirectory: true)
            if requiredDLLs.allSatisfy({ hasPE(custom.appendingPathComponent($0)) }) {
                return true
            }
        }
        let marker = prefix.appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return false }
        return paths.contains { directory in
            requiredDLLs.allSatisfy { hasPE(directory.appendingPathComponent($0)) }
        }
    }

    static func complete(in prefix: URL) -> Bool {
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        guard requiredDLLs.allSatisfy({ hasPE(system32.appendingPathComponent($0)) }) else {
            return false
        }
        let marker = prefix.appendingPathComponent(markerName)
        return FileManager.default.createFile(atPath: marker.path,
                                              contents: Data("Microsoft v14 x64 installed\n".utf8))
    }

    static func hasPE(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data([0x4D, 0x5A])
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
                guard (100_000...150_000_000).contains(size), hasPE(temporary) else {
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
