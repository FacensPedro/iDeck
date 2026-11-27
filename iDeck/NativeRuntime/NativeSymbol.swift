import Darwin
import Foundation

/// Addresses of Madeira's statically linked C entry points (`winios_*`,
/// `madeira_*`, `macdrv_functions`), looked up once. They are part of the app's
/// own binary and never change while it runs, so a repeated `dlsym` (a search
/// through every loaded image) is wasted work on per-second and per-layout paths.
/// An interface-only build has none of them: the answer, nil, is cached as well.
enum NativeSymbol {
    private static let lock = NSLock()
    private static var cache: [String: UnsafeMutableRawPointer?] = [:]

    static func address(_ name: String) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[name] { return known }
        let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        cache[name] = found
        return found
    }
}
