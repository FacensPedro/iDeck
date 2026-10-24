import Foundation
import Darwin

class ContainerHost {
    private var isMounted = false

    func setupContainer(injectHooks: Bool, completion: @escaping (Bool) -> Void) {
        let success = setupVirtualFileSystem()
        guard success else {
            isMounted = false
            completion(false)
            return
        }
        if injectHooks {
            LiveContainerHook.installHooks()
        }
        isMounted = true
        completion(true)
    }

    func mountEnvironment(completion: @escaping (String?) -> Void) {
        guard setupVirtualFileSystem(),
              let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            isMounted = false
            completion(nil)
            return
        }
        isMounted = true
        completion(documentDirectory.appendingPathComponent("VirtualRoot", isDirectory: true).path)
    }

    private func setupVirtualFileSystem() -> Bool {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let virtualRoot = documentDirectory.appendingPathComponent("VirtualRoot", isDirectory: true)
        let directories = [
            virtualRoot,
            virtualRoot.appendingPathComponent("Library", isDirectory: true),
            virtualRoot.appendingPathComponent("Documents", isDirectory: true),
            virtualRoot.appendingPathComponent("SystemData", isDirectory: true),
            virtualRoot.appendingPathComponent("tmp", isDirectory: true),
            virtualRoot.appendingPathComponent("GuestApps", isDirectory: true),
            virtualRoot.appendingPathComponent("Windows", isDirectory: true),
            virtualRoot.appendingPathComponent("WindowsDownloads", isDirectory: true),
            virtualRoot.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
        ]
        do {
            for directory in directories {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            setenv("TMPDIR", virtualRoot.appendingPathComponent("tmp").path, 1)
            setenv("HOME", virtualRoot.path, 1)
            return true
        } catch {
            print("ContainerHost: could not create virtual filesystem: \(error.localizedDescription)")
            return false
        }
    }
}