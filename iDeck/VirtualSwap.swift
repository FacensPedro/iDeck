import Foundation

/// iDeck Virtual Swap: game memory that the runtime keeps in a file on the device's
/// storage instead of in RAM, on Madeira's swap tier (build/ntdll-unix/virtual_ios.c).
/// Wine ARM64EC's memory manager, which FEX's guest memory goes through, maps the
/// game's allocations and the read pages of its x64 programs and DLLs from that file
/// (swap-mb, swap-mode 2 = broad coverage, swap-images). Those pages are file-backed:
/// under memory pressure iOS writes them to the file and drops them from RAM by itself,
/// and reads them back when the game touches them again, so they stop counting against
/// the app's memory limit. Anonymous memory left in RAM is compressed by iOS's own
/// memory compressor. iDeck sizes the file at each launch from the device's RAM and
/// free storage, and turns it off when storage is short.
enum VirtualSwap {
    static let enabledKey = "virtualSwap.enabled"
    /// Storage always left free for the system and downloads.
    static let storageReserveMB = 4096
    static let minimumMB = 1024
    static let maximumMB = 8192

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func freeStorageMB() -> Int {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / (1 << 20))
    }

    /// The file's size for this launch: as large as the device's RAM, at most 8 GB and
    /// never past what free storage allows; nil (off) under 1 GB.
    static func sizeMB(ramMB: Int = Int(ProcessInfo.processInfo.physicalMemory >> 20),
                       freeMB: Int = freeStorageMB()) -> Int? {
        let size = min(ramMB, maximumMB, freeMB - storageReserveMB)
        return size >= minimumMB ? size / 256 * 256 : nil
    }

    /// The session config lines. A game whose own list sets swap-mb keeps its value;
    /// with Virtual Swap off the swap tier is off for every game.
    static func configLines(existing: [String]) -> [String] {
        let setsSize = existing.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("swap-mb") }
        guard isEnabled else {
            AppLog.record("[virtual-swap] off (Settings)")
            return ["swap-mb = 0", "swap-images = 0"]
        }
        if setsSize { return [] }
        guard let size = sizeMB() else {
            AppLog.record("[virtual-swap] off for this launch: \(freeStorageMB()) MB of storage free")
            return []
        }
        AppLog.record("[virtual-swap] \(size) MB file for this launch (RAM \(ProcessInfo.processInfo.physicalMemory >> 20) MB, storage free \(freeStorageMB()) MB)")
        return ["swap-mb = \(size)", "swap-mode = 2", "swap-images = 1"]
    }
}
