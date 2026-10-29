import Foundation
import Combine
import UIKit
import QuartzCore
import Darwin

class SystemCoordinator: ObservableObject {
    @Published var isJITEnabled: Bool = false
    @Published var isStikDebugAttached: Bool = false
    @Published var isWineJITPrepared: Bool = false
    @Published var isContainerReady: Bool = false
    @Published var currentStatus: String = "Ready"
    @Published var windowsStatus: String = "Ready"
    @Published var liveContainerStatus: String = "Ready"
    @Published var isSteamConnected: Bool = false
    
    @Published var isHUDEnabled: Bool = false {
        didSet {
            windowsEnvironment.graphicsConfig.isHUDEnabled = isHUDEnabled
        }
    }
    
    @Published var isMetalFXEnabled: Bool = UserDefaults.standard.bool(forKey: "metalFXEnabled") {
        didSet {
            UserDefaults.standard.set(isMetalFXEnabled, forKey: "metalFXEnabled")
        }
    }
    
    @Published var isD3DMetalEnabled: Bool = false {
        didSet {
            windowsEnvironment.graphicsConfig.useD3DMetal = isD3DMetalEnabled
        }
    }
    
    @Published var isJITPoolEnabled: Bool = false
    /// Starts the LocalDevVPN extension before activating JIT. Off by default: the extension needs
    /// a provisioning profile with the Network Extensions capability, and the helper-server
    /// flow does not need it.
    @Published var isVPNJITEnabled: Bool = false
    @Published var hasPairingFile: Bool = false
    @Published var isGuestHooksEnabled: Bool = true
    
    @Published var isMaxRefreshRateEnabled: Bool = false {
        didSet {
            applyMaxRefreshRate()
        }
    }
    
    let jitEnabler = JITEnabler()
    let containerHost = ContainerHost()
    let windowsEnvironment = WindowsEnvironment()
    let prefixInstaller = PrefixInstaller()
    private var displayLink: CADisplayLink?
    private var steamSignInObserver: NSObjectProtocol?
    private var steamSignInLoaded = false
    private var nativeHostConfigured = false
    private var activeSteamGameID: UInt32?
    private var activeSteamPrefix: String?
    private var pendingSteamGameID: UInt32?
    private var wineJITPreparationInFlight = false
    private var wineJITAttemptedDuringAttachment = false
    @Published var needsVisualCRuntimeConsent = false
    private var visualCRuntimeConsentAction: (() -> Void)?
    private var visualCRuntimeSkipAction: (() -> Void)?
    private var bypassVisualCRuntimeForPrefix: String?

    init() {
        // Keep app startup free of native Wine/JIT probes and Keychain reads.
        // In particular, a CS_DEBUGGED flag left behind by StikDebug or a
        // previous Wine crash must not be used to initialize FEX on app open.
        // The Madeira workspace explicitly asks for these checks on entry.
        steamSignInObserver = NotificationCenter.default.addObserver(
            forName: SteamSignIn.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.steamSignInLoaded = true
            self.isSteamConnected = SteamSignIn.isSignedIn
        }
    }

    func configureNativeHostIfNeeded() {
        guard !nativeHostConfigured else { return }
        nativeHostConfigured = true
        ideck_native_memory_install_notifications()
        _ = ideck_native_memory_configure(64 * 1024 * 1024, 8 * 1024 * 1024)
    }

    func loadSteamAccountIfNeeded() {
        guard !steamSignInLoaded else { return }
        steamSignInLoaded = true
        isSteamConnected = SteamSignIn.isSignedIn
    }

    private func isLocalDevVPNActive() -> Bool {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        
        var current = interfaces
        while let interface = current {
            let name = String(cString: interface.pointee.ifa_name)
            let isTunnel = name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("ipsec")
            // System utun interfaces only carry IPv6 link-local addresses; a VPN with an
            // IPv4 address on a tunnel interface is what the JIT bridge needs.
            if isTunnel, let addr = interface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0 {
                return true
            }
            current = interface.pointee.ifa_next
        }
        return false
    }
    
    func setWindowsStatus(_ status: String) {
        let update = {
            self.windowsStatus = status
            self.currentStatus = status
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func setLiveContainerStatus(_ status: String) {
        let update = {
            self.liveContainerStatus = status
            self.currentStatus = status
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func refreshJITStatus() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        let debuggerAttached = result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
        // Query code-signing status without allocating executable memory.
        // Repeated MAP_JIT probes can race with FEX memory initialization and
        // do not establish that StikDebug's BRK handler is ready.
        let detected = ideck_process_has_jit_permission() || debuggerAttached
        let wineReady = ideck_wine_jit_pool_ready()
        let update = {
            if self.isJITEnabled != detected { self.isJITEnabled = detected }
            if self.isStikDebugAttached != debuggerAttached { self.isStikDebugAttached = debuggerAttached }
            if self.isWineJITPrepared != wineReady { self.isWineJITPrepared = wineReady }
            // Wine's RX/RW pool must be allocated while StikDebug is actively
            // servicing the Madeira BRK protocol. A persisted JIT entitlement
            // alone does not authorize safely entering jit26_prepare_region.
            if !debuggerAttached {
                self.wineJITAttemptedDuringAttachment = false
            } else if detected && !wineReady &&
                      !self.wineJITPreparationInFlight &&
                      !self.wineJITAttemptedDuringAttachment {
                let native = ideck_native_capabilities()
                if native.fex_linked && native.launcher_linked {
                    self.wineJITAttemptedDuringAttachment = true
                    self.wineJITPreparationInFlight = true
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let prepared = ideck_wine_jit_pool_prepare()
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.wineJITPreparationInFlight = false
                            self.isWineJITPrepared = prepared && ideck_wine_jit_pool_ready()
                            if !prepared {
                                SteamLog.event("[iDeck Wine JIT] automatic preparation failed; see native JIT diagnostics")
                            }
                        }
                    }
                }
            }
            if !detected && (self.currentStatus == "JIT confirmed via StikDebug" || self.currentStatus == "Ready") {
                self.currentStatus = "JIT not detected. Enable it in StikDebug and return to iDeck."
            }
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    func forceJITAndStartLiveContainer() {
        refreshJITStatus()
        guard isJITEnabled else {
            setLiveContainerStatus("Activate JIT with StikDebug, then confirm it in iDeck Settings.")
            return
        }
        startLiveContainer()
    }

    func reconnectStikDebugForWineIfNeeded() {
        refreshJITStatus()
        // CS_DEBUGGED can stay set after StikDebug's app-list activation
        // detaches its debugger. Send the bundled BRK script from Madeira
        // when the user opens this mode, even with a ready Wine prefix.
        if isJITEnabled && !isStikDebugAttached && !isWineJITPrepared {
            requestStikDebugJIT()
        }
    }

    func forceJITAndStartWindows() {
        startWindows()
        reconnectStikDebugForWineIfNeeded()
    }
    
    private func startLiveContainer() {
        setLiveContainerStatus("Initializing LiveContainer...")
        containerHost.setupContainer(injectHooks: isGuestHooksEnabled) { [weak self] success in
            DispatchQueue.main.async {
                self?.isContainerReady = success
                self?.setLiveContainerStatus(success ? "LiveContainer Running" : "Container Error")
            }
        }
    }
    
    private func startWindows() {
        setWindowsStatus("Preparing Windows Environment...")
        containerHost.setupContainer(injectHooks: isGuestHooksEnabled) { [weak self] setupSuccess in
            guard let self else { return }
            guard setupSuccess else {
                self.setWindowsStatus("Container initialization failed")
                return
            }

            self.containerHost.mountEnvironment { [weak self] mountPath in
                guard let self else { return }
                guard let mountPath else {
                    self.setWindowsStatus("Container not initialized")
                    return
                }

                DispatchQueue.main.async {
                    self.isContainerReady = true
                    guard Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil else {
                        self.setWindowsStatus("Library Ready — Madeira native runtime is not bundled")
                        return
                    }
                    self.setWindowsStatus("Preparing Wine prefix...")
                    self.prefixInstaller.installWinePrefix(to: mountPath) { success in
                        guard success else {
                            self.setWindowsStatus("Wine prefix setup failed")
                            return
                        }
                        self.windowsEnvironment.configureWine(prefix: mountPath)
                        self.setWindowsStatus(self.windowsEnvironment.hasRuntime(in: mountPath)
                            ? "Windows Runtime Ready" : "Madeira runtime components are missing")
                    }
                }
            }
        }
    }

    func requestStikDebugJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            setWindowsStatus("Cannot request JIT: missing iDeck bundle identifier.")
            return
        }
        // iOS does not expose SecTaskCreateFromSelf through the public Swift SDK.
        // StikDebug validates the target's get-task-allow entitlement when
        // attaching. A URL request must not be mistaken for JIT authorization.
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid()))
        ]
        if #available(iOS 26.0, *) {
            guard let scriptURL = Bundle.main.url(forResource: "universal", withExtension: "js"),
                  let scriptData = try? Data(contentsOf: scriptURL),
                  !scriptData.isEmpty else {
                setWindowsStatus("Cannot request JIT: the bundled universal.js debugger script is missing.")
                return
            }
            components.queryItems?.append(
                URLQueryItem(name: "script-data", value: scriptData.base64EncodedString())
            )
        }
        guard let url = components.url else {
            setWindowsStatus("Cannot create StikDebug request.")
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard let self else { return }
            self.setWindowsStatus(opened
                ? "StikDebug requested. Return to iDeck after JIT is enabled; FEX must still prepare its executable memory."
                : "StikDebug could not be opened. Install and configure StikDebug first.")
        }
    }

    func confirmJITActivatedByStikDebug() {
        refreshJITStatus()
    }

    func disconnectSteamAccount() {
        SteamSignIn.signOut()
        isSteamConnected = false
        currentStatus = "Steam disconnected"
    }

    private var pairingFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pairing_file.mobiledevicepairing")
    }
    
    func refreshPairingFileState() {
        hasPairingFile = FileManager.default.fileExists(atPath: pairingFileURL.path)
    }
    
    /// Imports a pairing file picked with the document picker. Files from the Files app are
    /// security-scoped: without startAccessingSecurityScopedResource the copy silently fails.
    func importPairingFile(at url: URL) {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        
        let fileManager = FileManager.default
        do {
            let data = try Data(contentsOf: url)
            // Pairing files exported by other tools (StikDebug, JitterBug, ...) are accepted as well:
            // a property list or JSON object that carries the usual pairing record keys.
            let knownKeys: Set<String> = ["HostID", "SystemBUID", "UDID", "DeviceCertificate", "HostCertificate",
                                          "HostPrivateKey", "RootCertificate", "RootPrivateKey", "private_key"]
            let object = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                ?? (try? JSONSerialization.jsonObject(with: data))
            guard let record = object as? [String: Any], !knownKeys.isDisjoint(with: record.keys) else {
                currentStatus = "Not a valid pairing file"
                return
            }
            if fileManager.fileExists(atPath: pairingFileURL.path) {
                try fileManager.removeItem(at: pairingFileURL)
            }
            try data.write(to: pairingFileURL, options: [.atomic, .completeFileProtection])
            hasPairingFile = true
            currentStatus = "Pairing file imported"
        } catch {
            currentStatus = "Pairing import failed: \(error.localizedDescription)"
        }
    }
    
    /// The JIT server mounts the Developer Disk Image itself; the picked files are not uploaded.
    func mountDDI(urls: [URL]) {
        currentStatus = "Mounting DDI..."
        jitEnabler.mountDeveloperDiskImage { [weak self] success in
            self?.currentStatus = success ? "DDI Mounted" : "DDI Mount Failed"
        }
    }
    
    private func applyMaxRefreshRate() {
        if isMaxRefreshRateEnabled {
            displayLink = CADisplayLink(target: self, selector: #selector(dummyDisplayLinkUpdate))
            if #available(iOS 15.0, *) {
                var maxFPS: Float = 60.0
                let scenes = UIApplication.shared.connectedScenes
                if let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                    maxFPS = Float(windowScene.screen.maximumFramesPerSecond)
                }
                displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: maxFPS, maximum: maxFPS, preferred: maxFPS)
            }
            displayLink?.add(to: .main, forMode: .common)
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
    
    @objc private func dummyDisplayLinkUpdate() {}
    
    func launchSteam() {
        guard isJITEnabled && isContainerReady else { return }
        guard ideck_fex_jit_ready() &&
              (ideck_wine_jit_pool_ready() || ideck_jit_debugger_attached()) else {
            setWindowsStatus("Cannot launch: StikDebug must remain attached to iDeck with the Madeira JIT script until FEX memory is prepared.")
            requestStikDebugJIT()
            return
        }

        setWindowsStatus("Downloading Steam...")
        containerHost.mountEnvironment { [weak self] mountPath in
            guard let self = self else { return }
            guard let mountPath = mountPath else {
                self.setWindowsStatus("Container not initialized")
                return
            }
            guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                DispatchQueue.main.async {
                    self.setWindowsStatus("Madeira runtime missing: in-process FEX, Wine ARM64EC, DXMT, D3D12 and native launch bridge are not linked.")
                }
                return
            }
            guard self.windowsEnvironment.hasWoW64Runtime() else {
                self.setWindowsStatus("Cannot install the Windows Steam client: this IPA does not contain a verified WoW64 runtime. Rebuild the Madeira-native IPA with WoW64 enabled (the default).")
                return
            }
            self.windowsEnvironment.configureWine(prefix: mountPath)
            self.windowsEnvironment.applyGameProfile(WindowsGameProfile(id: "steam", title: "Steam"))
            self.setWindowsStatus("Launching Steam client...")
            self.withPreparedMetalDisplay(expectedStatus: "Launching Steam client...") { [weak self] in
                guard let self else { return }
                self.windowsEnvironment.installAndRunSteam(jitEnabler: self.jitEnabler) { result in
                    DispatchQueue.main.async {
                        guard self.windowsStatus == "Launching Steam client..." else { return }
                        self.setWindowsStatus(result && ideck_wineprocess_running()
                            ? "Steam Running" : "Execution Error: Windows Steam client failed to start.")
                    }
                }
            }
        }
    }
    
    private func withPreparedMetalDisplay(expectedStatus: String, remainingChecks: Int = 100, perform: @escaping () -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.withPreparedMetalDisplay(expectedStatus: expectedStatus, remainingChecks: remainingChecks, perform: perform)
            }
            return
        }
        guard windowsStatus == expectedStatus else { return }
        if WindowsRendererView.isReadyForFrames {
            perform()
            return
        }
        guard remainingChecks > 0 else {
            pendingSteamGameID = nil
            setWindowsStatus("Execution Error: Metal display surface did not become ready. Wine was not started.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.withPreparedMetalDisplay(expectedStatus: expectedStatus,
                                           remainingChecks: remainingChecks - 1,
                                           perform: perform)
        }
    }

    func approveVisualCRuntimeInstallation() {
        guard let action = visualCRuntimeConsentAction else { return }
        needsVisualCRuntimeConsent = false
        visualCRuntimeConsentAction = nil
        visualCRuntimeSkipAction = nil
        UserDefaults.standard.set(true, forKey: "ideckInstallOfficialVisualCRedist")
        action()
    }

    func skipVisualCRuntimeInstallation() {
        let action = visualCRuntimeSkipAction
        guard action != nil else { return }
        needsVisualCRuntimeConsent = false
        visualCRuntimeConsentAction = nil
        visualCRuntimeSkipAction = nil
        action?()
    }

    private func prepareVisualCRuntimeIfNeeded(prefix: URL, resume: @escaping () -> Void) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                _ = self?.prepareVisualCRuntimeIfNeeded(prefix: prefix, resume: resume)
            }
            return true
        }
        let prefix = prefix.standardizedFileURL
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if VisualCRuntimeBootstrap.installed(in: prefix, documents: documents) {
            return false
        }
        if bypassVisualCRuntimeForPrefix == prefix.path {
            bypassVisualCRuntimeForPrefix = nil
            return false
        }
        if needsVisualCRuntimeConsent || windowsStatus == VisualCRuntimeBootstrap.installStatus {
            return true
        }
        if UserDefaults.standard.bool(forKey: "ideckInstallOfficialVisualCRedist") {
            beginVisualCRuntimeInstallation(prefix: prefix, resume: resume)
            return true
        }
        visualCRuntimeConsentAction = { [weak self] in
            self?.beginVisualCRuntimeInstallation(prefix: prefix, resume: resume)
        }
        visualCRuntimeSkipAction = { [weak self] in
            self?.bypassVisualCRuntimeForPrefix = prefix.path
            resume()
        }
        needsVisualCRuntimeConsent = true
        return true
    }

    private func beginVisualCRuntimeInstallation(prefix: URL, resume: @escaping () -> Void) {
        guard !ideck_wineprocess_running() else {
            setWindowsStatus("Visual C++ setup cannot start while another Wine session is running.")
            return
        }
        setWindowsStatus(VisualCRuntimeBootstrap.installStatus)
        VisualCRuntimeBootstrap.download(in: prefix) { [weak self] result in
            guard let self, self.windowsStatus == VisualCRuntimeBootstrap.installStatus else { return }
            switch result {
            case .failure(let error):
                self.setWindowsStatus("Visual C++ setup download failed: \(error.localizedDescription)")
            case .success(let installer):
                guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                               in: .userDomainMask).first else {
                    self.setWindowsStatus("Visual C++ extraction failed: Documents folder unavailable.")
                    return
                }
                VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: documents) { [weak self] result in
                    try? FileManager.default.removeItem(at: installer)
                    guard let self, self.windowsStatus == VisualCRuntimeBootstrap.installStatus else { return }
                    switch result {
                    case .success:
                        self.setWindowsStatus("Windows Ready")
                        resume()
                    case .failure(let error):
                        self.setWindowsStatus("Visual C++ extraction failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func launchWindowsExecutable(at url: URL, profile: WindowsGameProfile? = nil) {
        guard isContainerReady else { return }
        refreshJITStatus()

        guard url.pathExtension.lowercased() == "exe" else {
            setWindowsStatus("Choose a Windows .exe executable.")
            return
        }

        setWindowsStatus("Preparing executable...")
        let fileManager = FileManager.default
        let hasScope = url.startAccessingSecurityScopedResource()

        containerHost.mountEnvironment { [weak self] mountPath in
            defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            guard let mountPath else {
                self.setWindowsStatus("Container initialization failed")
                return
            }

            do {
                let root = URL(fileURLWithPath: mountPath, isDirectory: true)
                let downloads = root.appendingPathComponent("drive_c/WindowsDownloads", isDirectory: true)
                try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)

                let source = url.standardizedFileURL
                let downloadDirectory = downloads.standardizedFileURL
                let isAlreadyInLibrary = source.deletingLastPathComponent() == downloadDirectory
                let destination: URL

                if isAlreadyInLibrary {
                    guard fileManager.fileExists(atPath: source.path) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    destination = source
                } else {
                    var candidate = downloads.appendingPathComponent(url.lastPathComponent)
                    if fileManager.fileExists(atPath: candidate.path) {
                        let stem = candidate.deletingPathExtension().lastPathComponent
                        candidate = downloads.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).exe")
                    }
                    try fileManager.copyItem(at: url, to: candidate)
                    destination = candidate
                }

                guard self.isJITEnabled else {
                    self.setWindowsStatus("Executable is in the library. Enable JIT in Settings before launching.")
                    return
                }
                guard ideck_fex_jit_ready() &&
                      (ideck_wine_jit_pool_ready() || ideck_jit_debugger_attached()) else {
                    self.setWindowsStatus("Executable imported. JIT permission is present but StikDebug is no longer attached. Attach it to iDeck with the Madeira JIT script and retry.")
                    self.requestStikDebugJIT()
                    return
                }

                let launchPrepared: () -> Void = { [weak self] in
                    guard let self else { return }
                    guard self.windowsEnvironment.hasRuntime(in: mountPath) else {
                        let missing = self.windowsEnvironment.missingRuntimeComponents(in: mountPath)
                        self.setWindowsStatus("Madeira runtime missing: " + missing.joined(separator: ", "))
                        return
                    }
                    let prefix = URL(fileURLWithPath: mountPath, isDirectory: true)
                    if self.prepareVisualCRuntimeIfNeeded(prefix: prefix, resume: { [weak self] in
                        self?.launchWindowsExecutable(at: destination, profile: profile)
                    }) { return }
                    self.windowsEnvironment.configureWine(prefix: mountPath)
                    var effectiveProfile = profile ?? WindowsGameProfile(id: destination.path, title: destination.deletingPathExtension().lastPathComponent)
                    if self.isMetalFXEnabled { effectiveProfile.metalFXEnabled = true }
                    self.windowsEnvironment.applyGameProfile(effectiveProfile)
                    self.setWindowsStatus("Launching Windows app...")
                    self.withPreparedMetalDisplay(expectedStatus: "Launching Windows app...") { [weak self] in
                        guard let self else { return }
                        guard !ideck_wineprocess_running() else {
                            self.setWindowsStatus("Execution Error: another Wine process is already running.")
                            return
                        }
                        self.windowsEnvironment.execute(
                            binary: destination,
                            arguments: profile?.arguments ?? "",
                            is32Bit: false,
                            isSteam: false,
                            jitEnabler: self.jitEnabler
                        ) { [weak self] result in
                            DispatchQueue.main.async {
                                guard let self, self.windowsStatus == "Launching Windows app..." else { return }
                                self.setWindowsStatus(result == 0 && ideck_wineprocess_running()
                                    ? "Running" : self.nativeLaunchFailure(result))
                            }
                        }
                    }
                }

                let prefixURL = URL(fileURLWithPath: mountPath, isDirectory: true)
                if !PrefixInstaller.isPrefixInstalled(at: prefixURL) &&
                    Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil {
                    self.setWindowsStatus("Preparing Wine prefix...")
                    self.prefixInstaller.installWinePrefix(to: mountPath) { [weak self] success in
                        if success {
                            launchPrepared()
                        } else {
                            self?.setWindowsStatus("Wine prefix setup failed")
                        }
                    }
                } else {
                    launchPrepared()
                }
            } catch {
                self.setWindowsStatus("Executable import failed: \(error.localizedDescription)")
            }
        }
    }

    /// Launches a Steam game in its original installation directory, preserving
    /// relative DLL and asset paths instead of copying the executable elsewhere.
    func launchSteamGame(game: SteamAppInfo, profile: WindowsGameProfile, prefixPath: URL) {
        refreshJITStatus()
        if let pendingSteamGameID {
            setWindowsStatus(pendingSteamGameID == game.appID
                ? "Launching Steam game..."
                : "Cannot launch: a different Steam game is already starting.")
            return
        }
        let standardizedPrefix = prefixPath.standardizedFileURL.path
        if ideck_wineprocess_running() {
            guard activeSteamGameID == game.appID, activeSteamPrefix == standardizedPrefix else {
                setWindowsStatus("Cannot launch: Wine is already running a different or unverified session. Exit that Wine session before launching this game.")
                return
            }
            setWindowsStatus("Running")
            return
        }
        activeSteamGameID = nil
        activeSteamPrefix = nil

        let steamApps = SteamInstallPaths.steamApps(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
        guard SteamInstallFiles.buildID(appID: Int(game.appID), steamApps: steamApps) != nil else {
            setWindowsStatus("Cannot launch: this Steam game is not installed.")
            return
        }

        let folderName = SteamInstallFiles.installDirectoryName(
            appID: Int(game.appID), steamApps: steamApps) ??
            SteamInstallFiles.safeFolderName(
                game.installDir.isEmpty ? "app_\(game.appID)" : game.installDir)
        let directory = SteamInstallPaths.common(
            drive: prefixPath.appendingPathComponent("drive_c", isDirectory: true))
            .appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            setWindowsStatus("Cannot launch: the installed game folder is missing.")
            return
        }
        guard let selected = steamExecutable(game: game, directory: directory) else {
            setWindowsStatus("Cannot launch: no Windows .exe was found in this game's installed files.")
            return
        }
        let executableURL = selected.url
        let entryArguments = selected.arguments
        SteamLog.event("[steam-start] app=\(game.appID) exe=\(executableURL.lastPathComponent) cwd=\(selected.workingDirectory.lastPathComponent) source=\(selected.source)")
        if !PrefixInstaller.isPrefixInstalled(at: prefixPath) &&
            Bundle.main.url(forResource: "prefix-template", withExtension: "tar.gz") != nil {
            setWindowsStatus("Preparing Wine prefix...")
            prefixInstaller.installWinePrefix(to: prefixPath.path) { [weak self] success in
                guard let self else { return }
                if success {
                    self.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath)
                } else {
                    self.setWindowsStatus("Wine prefix setup failed")
                }
            }
            return
        }
        guard windowsEnvironment.hasRuntime(in: prefixPath.path) else {
            let missing = windowsEnvironment.missingRuntimeComponents(in: prefixPath.path)
            setWindowsStatus("Madeira runtime missing: " + missing.joined(separator: ", ") +
                             ". Compile and link the native runtime into the iDeck IPA.")
            return
        }

        guard ideck_fex_jit_ready() &&
              (ideck_wine_jit_pool_ready() || ideck_jit_debugger_attached()) else {
            setWindowsStatus("FEX/Wine JIT is not ready. Request StikDebug with universal.js from Madeira and retry.")
            requestStikDebugJIT()
            return
        }
        if prepareVisualCRuntimeIfNeeded(prefix: prefixPath, resume: { [weak self] in
            self?.launchSteamGame(game: game, profile: profile, prefixPath: prefixPath)
        }) { return }
        windowsEnvironment.configureWine(prefix: prefixPath.path)
        windowsEnvironment.graphicsConfig.applyGraphicsEnvironment()
        var effectiveProfile = profile
        if isMetalFXEnabled { effectiveProfile.metalFXEnabled = true }
        windowsEnvironment.applyGameProfile(effectiveProfile)
        pendingSteamGameID = game.appID
        setWindowsStatus("Launching Steam game...")
        withPreparedMetalDisplay(expectedStatus: "Launching Steam game...") { [weak self] in
            guard let self, self.pendingSteamGameID == game.appID else { return }
            guard self.windowsStatus == "Launching Steam game..." else {
                self.pendingSteamGameID = nil
                return
            }
            guard !ideck_wineprocess_running() else {
                self.pendingSteamGameID = nil
                self.setWindowsStatus("Execution Error: another Wine process started during game preparation.")
                return
            }
            self.windowsEnvironment.execute(binary: executableURL,
                                            arguments: profile.arguments.isEmpty ? entryArguments : profile.arguments,
                                            steamAppID: game.appID,
                                            steamInstallDirectory: directory,
                                            steamWorkingDirectory: selected.workingDirectory,
                                            jitEnabler: self.jitEnabler) { [weak self] success in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingSteamGameID = nil
                    let running = success == 0 && ideck_wineprocess_running()
                    if running {
                        self.activeSteamGameID = game.appID
                        self.activeSteamPrefix = standardizedPrefix
                    } else {
                        self.activeSteamGameID = nil
                        self.activeSteamPrefix = nil
                    }
                    if self.windowsStatus == "Launching Steam game..." {
                        // Wine reports its loader thread as running before
                        // the requested game's executable reaches first frame.
                        self.setWindowsStatus(running
                            ? "Wine started; waiting for game..." : self.nativeLaunchFailure(success))
                    }
                }
            }
        }
    }

    func refreshWindowsSessionHealth() {
        guard windowsStatus == "Running" || windowsStatus == "Steam Running" ||
              windowsStatus == "Wine started; waiting for game..." else { return }
        guard !ideck_wineprocess_running() else { return }
        activeSteamGameID = nil
        activeSteamPrefix = nil
        pendingSteamGameID = nil
        var exitCode: Int32 = 0
        var crashStatus: UInt32 = 0
        let code = ideck_wineprocess_last_exit_code(&exitCode) ? exitCode : nil
        let ntstatus = ideck_wineprocess_last_ntstatus(&crashStatus) ? crashStatus : nil
        let reason = WineExitDiagnostics.message(exitCode: code, crashStatus: ntstatus)
        SteamLog.event("[wine-exit] \(reason)")
        setWindowsStatus(reason)
    }

    private func nativeLaunchFailure(_ status: Int) -> String {
        if status == 0 || status == Int(EAGAIN) {
            var exitCode: Int32 = 0
            var crashStatus: UInt32 = 0
            let code = ideck_wineprocess_last_exit_code(&exitCode) ? exitCode : nil
            let ntstatus = ideck_wineprocess_last_ntstatus(&crashStatus) ? crashStatus : nil
            return WineExitDiagnostics.message(exitCode: code, crashStatus: ntstatus)
        }
        if status == Int(ENOTSUP) {
            return "Execution Error: 32-bit Windows support (WoW64) is missing from this IPA."
        }
        if status == Int(EPERM) {
            return "Execution Error: FEX/Wine JIT requires StikDebug to stay attached until both executable-memory pools are prepared. Request JIT inside iDeck with its bundled debugger script."
        }
        if status == Int(ENOENT) {
            return "Execution Error: Wine prefix or runtime components are missing."
        }
        if status == Int(EINVAL) {
            return "Execution Error: invalid Windows launch request (code 22). Check the executable format, Steam game metadata and launch arguments. The iDeck console identifies rejected native parameters under [iDeck native launch] EINVAL or [wine-launch]."
        }
        if status == Int(ENOMEM) {
            let machCode = ideck_wine_jit_pool_failure_mach_code()
            let machDetail = machCode == 0 ? "" : " (Mach code \(machCode))"
            switch ideck_wine_jit_pool_failure_stage() {
            case 1:
                return "Execution Error: StikDebug disconnected before Wine could prepare executable memory. Request JIT from iDeck with the bundled BRK script."
            case 2:
                return "Execution Error: StikDebug could not allocate the Wine executable RX region, including smaller pools. Keep the debugger attached and check available virtual memory."
            case 3:
                let cause: String
                switch ideck_wine_jit_pool_failure_rx_detail() {
                case 1: cause = "The JIT RX address is below Madeira's required FEX frontier."
                case 2: cause = "The RX address range overflowed."
                case 3: cause = "The RX region exceeds the supported virtual-memory layout."
                case 4: cause = "The RX region overlaps the Windows executable-image address window."
                case 5: cause = "The RX region is not page-aligned."
                case 6: cause = "Mach could not inspect the RX region."
                case 7: cause = "The RX region contains an unmapped gap."
                case 8: cause = "A page in the RX region lacks executable permission."
                default: cause = "The RX region failed validation."
                }
                return "Execution Error: Wine's RX pool was rejected: \(cause) Restart iDeck, request StikDebug JIT from Madeira and check [iDeck Wine JIT] logs. Do not reuse a JIT pool after a crash."
            case 4:
                return "Execution Error: Wine's executable RX region was allocated, but iPadOS denied its writable RW mirror\(machDetail). Check [iDeck Wine JIT] logs."
            case 5:
                return "Execution Error: iPadOS denied write access to the Wine JIT RW mirror\(machDetail). Check [iDeck Wine JIT] logs."
            case 6:
                return "Execution Error: Wine JIT memory exists, but the RX/RW addresses could not be exported to the guest environment."
            default:
                return "Execution Error: the Wine ARM64EC executable JIT pool could not be prepared. Check the [iDeck Wine JIT] diagnostics."
            }
        }
        let message = status > 0 && status < 256
            ? String(cString: strerror(Int32(status))) : "unknown native error"
        return "Execution Error: Madeira launch failed (code \(status): \(message))."
    }

    private func steamExecutable(game: SteamAppInfo, directory: URL)
        -> (url: URL, arguments: String, workingDirectory: URL, source: String)? {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL

        let preferred = game.launches.enumerated().filter { _, option in
            let platforms = option.oslist.lowercased()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            return (platforms.isEmpty || platforms.contains("windows")) &&
                   (option.requiredDLC?.isEmpty != false)
        }.sorted { left, right in
            // Prefer the normal Windows game over editors, tools and VR,
            // retaining Valve's configuration order for equal priorities.
            func priority(_ option: SteamLaunchOption) -> Int {
                let type = option.type.lowercased()
                let special = ["vr", "server", "editor", "launcher", "tool"]
                    .contains(where: { type.contains($0) })
                let arch64 = option.osarch == "64"
                return (special ? 100 : 0) + (arch64 ? 0 : 10)
            }
            let a = priority(left.element), b = priority(right.element)
            return a == b ? left.offset < right.offset : a < b
        }

        for (_, option) in preferred {
            guard let executable = SteamInstallFiles.resolveLaunchPath(
                option.executable, root: root, executable: true) else { continue }
            let requestedDir = option.workingDir.trimmingCharacters(in: .whitespacesAndNewlines)
            let workdir: URL
            if requestedDir.isEmpty {
                workdir = executable.deletingLastPathComponent()
            } else if let resolved = SteamInstallFiles.resolveLaunchPath(
                requestedDir, root: root, executable: false) {
                workdir = resolved
            } else {
                // Steam can provide a stale/unsupported workingdir. Keep
                // relative DLL and asset lookups inside the EXE's folder.
                SteamLog.event("[steam-start] app=\(game.appID) invalid workingdir for option \(option.index ?? 0); using exe directory")
                workdir = executable.deletingLastPathComponent()
            }
            return (executable, option.arguments, workdir,
                    "steam-config-\(option.index ?? 0)")
        }

        let blockedNames = Set([
            "unins000.exe", "uninstall.exe", "setup.exe", "install.exe",
            "crashreporter.exe", "unitycrashhandler64.exe",
            "unitycrashhandler32.exe", "dxsetup.exe", "vcredist.exe",
            "steamsetup.exe", "vc_redist.x64.exe", "vc_redist.x86.exe"
        ])
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var candidates: [(url: URL, score: Int)] = []
        var visited = 0
        let expectedNames = [game.installDir, game.name]
            .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty }
        for case let entry as URL in enumerator {
            visited += 1
            if visited > 20_000 || candidates.count >= 256 { break }
            guard entry.pathExtension.lowercased() == "exe",
                  !blockedNames.contains(entry.lastPathComponent.lowercased()),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(resolved.path.dropFirst(root.path.count + 1))
            guard relative.split(separator: "/").count <= 6 else { continue }
            let basename = entry.deletingPathExtension().lastPathComponent
                .lowercased().filter { $0.isLetter || $0.isNumber }
            let depth = relative.split(separator: "/").count
            let isLikelyGame = expectedNames.contains(basename)
            let isTool = relative.lowercased().contains("redist") ||
                         relative.lowercased().contains("prereq") ||
                         relative.lowercased().contains("engine/binaries") ||
                         basename.contains("crash") || basename.contains("uninstall")
            let score = (isLikelyGame ? 100 : 0) + (isTool ? -100 : 0) -
                        depth * 10
            candidates.append((resolved, score))
        }
        guard let best = candidates.sorted(by: {
            $0.score == $1.score
                ? $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
                : $0.score > $1.score
        }).first, best.score > -100 else { return nil }
        SteamLog.event("[steam-start] app=\(game.appID) using executable fallback; Steam metadata did not resolve")
        return (best.url, "", best.url.deletingLastPathComponent(), "installed-files")
    }

    /// Loads and starts a guest .app inside this process (see LiveContainerHook).
    func launchGuestApp(at url: URL) {
        guard isJITEnabled && isContainerReady else {
            setLiveContainerStatus("Requires JIT & LiveContainer")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            setLiveContainerStatus("Guest app not found")
            return
        }
        
        setLiveContainerStatus("Launching: \(url.lastPathComponent)")
        var message: NSString?
        if LiveContainerHook.launchGuestApp(atPath: url.path, errorMessage: &message) {
            setLiveContainerStatus("Guest app running: \(url.lastPathComponent)")
        } else {
            setLiveContainerStatus("Guest launch failed: \(message ?? "O carregador não conseguiu abrir este aplicativo.")")
        }
    }
}
