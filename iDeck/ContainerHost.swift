import Foundation
import Darwin

class ContainerHost {
    private let containerIdentifier = "com.livecontainer.host"
    private var isMounted = false
    
    func setupContainer(injectHooks: Bool, completion: @escaping (Bool) -> Void) {
        guard setupVirtualFileSystem() else {
            completion(false)
            return
        }
        if injectHooks {
            injectLiveContainerHooks()
        }
        isMounted = true
        completion(true)
    }

    /// Calls `completion` with the virtual root path, or `nil` if the container was never set up.
    func mountEnvironment(completion: @escaping (String?) -> Void) {
        guard isMounted,
              let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            completion(nil)
            return
        }
        completion(documentDirectory.appendingPathComponent("VirtualRoot").path)
    }

    private func setupVirtualFileSystem() -> Bool {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        
        let virtualRoot = documentDirectory.appendingPathComponent("VirtualRoot")
        let directories = [
            virtualRoot,
            virtualRoot.appendingPathComponent("Library"),
            virtualRoot.appendingPathComponent("Documents"),
            virtualRoot.appendingPathComponent("SystemData"),
            virtualRoot.appendingPathComponent("tmp"),
            virtualRoot.appendingPathComponent("GuestApps")
        ]
        
        for directory in directories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("ContainerHost: could not create \(directory.path): \(error)")
                return false
            }
        }
        
        setenv("TMPDIR", virtualRoot.appendingPathComponent("tmp").path, 1)
        setenv("HOME", virtualRoot.path, 1)
        return true
    }
    
    private func injectLiveContainerHooks() {
        let bundlePath = Bundle.main.bundlePath
        let tweakPath = bundlePath.appending("/LiveContainerHook.dylib")
        // Setting this in the running process does not affect dyld for the current image;
        // it is only inherited by child processes spawned from here.
        if FileManager.default.fileExists(atPath: tweakPath) {
            setenv("DYLD_INSERT_LIBRARIES", tweakPath, 1)
        }
    }
}
