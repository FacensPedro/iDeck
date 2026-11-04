import Darwin

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
