import Darwin
import Foundation

/// Whether iOS gives this process the extended address space Madeira's guest
/// window needs ([0x7000000000, 0x7400000000)). Without the extended
/// virtual addressing entitlement the process stops at 64 GB, the guest
/// window cannot exist and wineserver crashes right after Wine starts.
enum AddressSpaceCheck {
    static let guestWindow: vm_address_t = 0x70_0000_0000

    static let hasGuestWindow: Bool = {
        var address = guestWindow
        let size = vm_size_t(vm_page_size)
        let result = vm_allocate(mach_task_self_, &address, size, VM_FLAGS_FIXED)
        if result == KERN_SUCCESS { vm_deallocate(mach_task_self_, address, size) }
        // Only "address out of range" proves the window is missing; a mapping
        // already there (the pool or Wine) or another error is not taken as one.
        return result != KERN_INVALID_ADDRESS
    }()

    static let message = "Execution Error: iOS did not give iDeck the extended memory address space Windows games need. Sign iDeck again with the extended virtual addressing entitlement (com.apple.developer.kernel.extended-virtual-addressing) and reopen it."
}

/// Memory+: the two memory capabilities Windows games need from iOS, and how a
/// sideloaded iDeck gets them. The IPA asks for both (iDeck.entitlements), but the
/// signature made at install time keeps an entitlement only when the App ID's
/// provisioning profile authorizes it. GetMoreRam adds "Increased Memory Limit" to an
/// App ID from the device, without Xcode; the app must then be installed again so it
/// is signed with the new profile.
enum MemoryPlus {
    static let increasedLimitKey = "com.apple.developer.kernel.increased-memory-limit"
    static let extendedAddressingKey = "com.apple.developer.kernel.extended-virtual-addressing"
    static let getMoreRamURL = URL(string: "https://github.com/hugeBlack/GetMoreRam")!

    enum State: Equatable { case granted, missing, unknown }

    /// The Entitlements dictionary of a provisioning profile: a CMS envelope around an
    /// XML property list, which is read between its first "<?xml" and "</plist>".
    static func entitlements(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }

    /// What the profile this copy of iDeck was signed with authorizes; nil when the
    /// bundle carries no profile (a simulator or an unsigned development build).
    static let profileEntitlements: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return entitlements(inProfile: data)
    }()

    static func state(_ key: String, in entitlements: [String: Any]?) -> State {
        guard let entitlements else { return .unknown }
        return (entitlements[key] as? Bool) == true ? .granted : .missing
    }

    /// Increased Memory Limit, as the signing profile authorizes it.
    static var increasedLimit: State { state(increasedLimitKey, in: profileEntitlements) }

    /// Extended Virtual Addressing, measured: iOS either maps the guest window or not.
    static var extendedAddressing: State { AddressSpaceCheck.hasGuestWindow ? .granted : .missing }

    /// The App ID to pick in GetMoreRam's "App IDs" list.
    static var appID: String { Bundle.main.bundleIdentifier ?? "" }

    static var ready: Bool { increasedLimit != .missing && extendedAddressing == .granted }

    /// GetMoreRam's own steps, with iDeck named as the app.
    static let getMoreRamSteps = [
        "Install GetMoreRam the way iDeck was installed (SideStore or AltStore).",
        "In GetMoreRam's settings, sign in with the Apple Account that signed iDeck.",
        "Open App IDs, tap Refresh and choose iDeck's App ID.",
        "Tap Add Increased Memory Limit.",
        "Install iDeck again from SideStore or AltStore, then open it and check this page.",
    ]
}
