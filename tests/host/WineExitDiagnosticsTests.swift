import Foundation

@main
struct WineExitDiagnosticsTests {
    static func main() {
        let dll = WineExitDiagnostics.message(exitCode: 1, crashStatus: 0xC0000135)
        assert(dll.contains("0xC0000135"))
        assert(dll.contains("DLL"))
        assert(WineExitDiagnostics.message(exitCode: 1, crashStatus: 0xC000007B).contains("architecture"))
        assert(WineExitDiagnostics.message(exitCode: 255, crashStatus: 0xC0000005).contains("access violation"))
        assert(WineExitDiagnostics.message(exitCode: 1, crashStatus: 0xC000001D).contains("unsupported CPU"))
        let normal = WineExitDiagnostics.message(exitCode: 0, crashStatus: nil)
        assert(!normal.contains("Execution Error"))
        assert(normal.contains("closed normally"))
        assert(WineExitDiagnostics.message(exitCode: 87, crashStatus: nil).contains("87"))
        assert(WineExitDiagnostics.message(exitCode: nil, crashStatus: nil).contains("no native exit code"))
        print("PASS: Wine native exit diagnostics")
    }
}
