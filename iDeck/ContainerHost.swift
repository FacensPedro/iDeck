import Foundation
import Darwin

/// Creates the on-device Wine prefix used exclusively by Madeira.
final class MadeiraPrefixHost {
    func mountEnvironment(completion: @escaping (String?) -> Void) {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            completion(nil)
            return
        }
        let wine = documents.appendingPathComponent("wine", isDirectory: true)
        let paths = [
            wine,
            wine.appendingPathComponent("Library", isDirectory: true),
            wine.appendingPathComponent("Documents", isDirectory: true),
            wine.appendingPathComponent("SystemData", isDirectory: true),
            wine.appendingPathComponent("tmp", isDirectory: true),
            wine.appendingPathComponent("Windows", isDirectory: true),
            wine.appendingPathComponent("WindowsDownloads", isDirectory: true),
            wine.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
        ]
        do {
            for path in paths {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            }
            setenv("TMPDIR", wine.appendingPathComponent("tmp").path, 1)
            setenv("HOME", wine.path, 1)
            completion(wine.path)
        } catch {
            AppLog.record("[madeira-prefix] failed to prepare Wine prefix: \(error.localizedDescription)")
            completion(nil)
        }
    }
}
