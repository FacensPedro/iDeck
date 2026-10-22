import Foundation
import Darwin

class ContainerHost {
    private var isMounted = false

    func setupContainer(injectHooks: Bool, completion: @escaping (Bool) -> Void) {
        guard setupVirtualFileSystem() else {
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
        guard isMounted,
              let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            completion(nil)
            return
        }

        let virtualRoot = documentDirectory.appendingPathComponent("VirtualRoot", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: virtualRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            isMounted = false
            completion(nil)
            return
        }

        completion(virtualRoot.path)
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
            virtualRoot.appendingPathComponent("GuestApps", isDirectory: true)
        ]

        for directory in directories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("ContainerHost: could not create \(directory.path): \(error.localizedDescription)")
                return false
            }
        }

        setenv("TMPDIR", virtualRoot.appendingPathComponent("tmp").path, 1)
        setenv("HOME", virtualRoot.path, 1)
        return true
    }
}
