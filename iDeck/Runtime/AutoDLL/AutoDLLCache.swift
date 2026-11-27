// AutoDLLManager: download from the publisher and the DLL cache.
// Split from AutoDLLManager.swift (iDeck 3.0 architecture).

import Foundation

extension AutoDLLManager {
    static var cacheRoot: URL {
        WindowsInstallerEnvironment.documents.appendingPathComponent("iDeck/DLL Cache", isDirectory: true)
    }

    static func cacheFolder(_ component: Component, machine: UInt16) -> URL {
        cacheRoot.appendingPathComponent(component.id, isDirectory: true)
            .appendingPathComponent(machine == 0x014C ? "x86" : "x64", isDirectory: true)
    }

    static let marker = ".ready"

    static func isCached(_ component: Component) -> Bool {
        [UInt16(0x014C), 0x8664].allSatisfy {
            FileManager.default.fileExists(atPath: cacheFolder(component, machine: $0).appendingPathComponent(marker).path)
        }
    }

    nonisolated(unsafe) static var downloading: Set<String> = []

    /// Downloads the component once and keeps both architectures' DLLs.
    static func prepare(_ component: Component) async throws {
        if isCached(component) { return }
        let fm = FileManager.default
        var request = URLRequest(url: component.url)
        request.timeoutInterval = 180
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? fm.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, VisualCRuntimeBootstrap.isTrustedDownloadURL(final) else {
            throw NSError(domain: "iDeck.autodll", code: 1, userInfo: [NSLocalizedDescriptionKey: "untrusted or failed download"])
        }
        let size = (try fm.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard component.sizeRange.contains(size), VisualCRuntimeBootstrap.hasPE(temporary, machines: [0x014C]) else {
            throw NSError(domain: "iDeck.autodll", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected file (\(size) bytes)"])
        }
        let installer = temporary
        try await Task.detached(priority: .utility) {
            for machine: UInt16 in [0x014C, 0x8664] { try extract(component, from: installer, machine: machine) }
        }.value
        AppLog.record("[auto-dll] \(component.title) cached for later games")
    }

    static func extract(_ component: Component, from installer: URL, machine: UInt16) throws {
        let fm = FileManager.default
        let folder = cacheFolder(component, machine: machine)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = component.dlls.map { $0 + ".dll" }
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
        AppLog.record("[auto-dll] \(component.id) \(machine == 0x014C ? "x86" : "x64"): \(count) of \(names.count) DLLs (\(String(cString: message)))")
        guard count > 0 else { throw NSError(domain: "iDeck.autodll", code: Int(count)) }
        fm.createFile(atPath: folder.appendingPathComponent(marker).path, contents: Data())
    }

    /// Starts the download in the background (once at a time per component).
    static func prefetch(_ component: Component) {
        guard !isCached(component), !downloading.contains(component.id) else { return }
        downloading.insert(component.id)
        Task.detached(priority: .utility) {
            do { try await prepare(component) } catch {
                AppLog.record("[auto-dll] \(component.title): download failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { downloading.remove(component.id) }
        }
    }
}
