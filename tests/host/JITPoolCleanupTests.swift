import Foundation
typealias vm_address_t = UInt
typealias vm_size_t = UInt
let mach_task_self_ = 1
var released: [(UInt, UInt)] = []
@discardableResult func vm_deallocate(_ task: Int, _ base: UInt, _ size: UInt) -> Int {
    released.append((base, size)); return 0
}
struct SigningStatus { var debugged: Bool; static var current = SigningStatus(debugged: true) }
var attached = false
var validPool = false
func isDebuggerAttached() -> Bool { attached }
func ideck_wine_jit_pool_ready() -> Bool { validPool }
enum Pool {
    static var poolTaken = true
    static var poolHole: (off: Int, end: Int)?
    static var poolHole2: (off: Int, end: Int)?
    static var poolMid: (base: UInt, size: UInt)?
    static var poolLow: (rx: Int, size: Int)?
/* ACTUAL_READY */
/* ACTUAL_DISCARD */
    static func attempt(succeed: Bool) {
        let rxPtr = UnsafeMutableRawPointer(bitPattern: 0x10000)!
        let poolSize = 0x4000
/* ACTUAL_DEFER */
        if succeed { retainPrimaryRX = true }
    }
}
@main struct Tests {
    static func main() {
        Pool.attempt(succeed: false);precondition(released.count == 1 && released[0].0 == 0x10000 && released[0].1 == 0x4000)
        released=[];Pool.attempt(succeed: true);precondition(released.isEmpty)
        Pool.poolHole=(0x1000,0x2000);Pool.poolHole2=(0x3000,0x4000)
        Pool.poolLow=(0x8000,0x1000)
        Pool.discardPool((UnsafeMutableRawPointer(bitPattern: 0x10000)!,UnsafeMutableRawPointer(bitPattern: 0x30000)!,0x5000))
        let expected: [(UInt, UInt)] = [(0x10000,0x1000),(0x12000,0x1000),(0x14000,0x1000),(0x8000,0x1000),(0x28000,0xd000)]
        precondition(released.count == expected.count)
        for (actual, want) in zip(released, expected) { precondition(actual.0==want.0 && actual.1==want.1) }
        precondition(!Pool.poolTaken && Pool.poolHole == nil && Pool.poolHole2 == nil && Pool.poolLow == nil)
        // A legacy poolTaken flag cannot make invalid exported memory ready.
        Pool.poolTaken=true;precondition(!Pool.ready)
        attached=true;precondition(Pool.ready)
        attached=false;validPool=true;precondition(Pool.ready)
        SigningStatus.current.debugged=false;precondition(!Pool.ready)
        print("PASS: failed RX allocation cleanup, retained successful mappings, split stack holes and strict readiness")
    }
}
