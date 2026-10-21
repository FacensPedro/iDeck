import Foundation
import Darwin

class ContainerHost {
    private let containerIdentifier = "com.livecontainer.host"
    private var isMounted = false
    
    func setupContainer(bypassAMFI: Bool, injectHooks: Bool, completion: @escaping (Bool) -> Void) {
        let dyldPath = "/usr/lib/dyld"
        var info = dl_info()
        
        if dladdr(dyldPath, &info) != 0 {
            if bypassAMFI {
                bypassSignatureChecks()
            }
            setupVirtualFileSystem()
            if injectHooks {
                injectLiveContainerHooks()
            }
            isMounted = true
            completion(true)
        } else {
            completion(false)
        }
    }
    
    func mountEnvironment(completion: @escaping (String) -> Void) {
        guard isMounted else { return }
        
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let virtualRoot = documentDirectory.appendingPathComponent("VirtualRoot")
        
        completion(virtualRoot.path)
    }
    
    private func setupVirtualFileSystem() {
        let fileManager = FileManager.default
        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
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
            if !fileManager.fileExists(atPath: directory.path) {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        
        setenv("TMPDIR", virtualRoot.appendingPathComponent("tmp").path, 1)
        setenv("HOME", virtualRoot.path, 1)
    }
    
    private func bypassSignatureChecks() {
        let handle = dlopen(nil, RTLD_NOW)
        let amfiSymbol = dlsym(handle, "AMFI_bypass")
        if amfiSymbol != nil {
            typealias BypassFunction = @convention(c) () -> Void
            let function = unsafeBitCast(amfiSymbol, to: BypassFunction.self)
            function()
        }
    }
    
    private func injectLiveContainerHooks() {
        let bundlePath = Bundle.main.bundlePath
        let tweakPath = bundlePath.appending("/LiveContainerHook.dylib")
        if FileManager.default.fileExists(atPath: tweakPath) {
            setenv("DYLD_INSERT_LIBRARIES", tweakPath, 1)
        }
    }
}
