import Foundation

@main
struct WindowsLaunchProgressTests {
    static func main() {
        var progress = 0
        for (status, expected) in [
            ("Preparing game launch...", 10),
            ("Preparing Wine prefix...", 20),
            ("Installing Microsoft Visual C++...", 35),
            ("Launching Steam game...", 70),
            ("Running", 90)
        ] {
            progress = WindowsLaunchProgress.advance(current: progress, status: status)
            assert(progress == expected)
        }
        assert(WindowsLaunchProgress.advance(current: 10, status: "Preparing executable...") == 20)
        assert(WindowsLaunchProgress.shouldDisplay(status: "Preparing executable...", percentage: 20))
        assert(progress == 90)
        assert(WindowsLaunchProgress.shouldDisplay(status: "Running", percentage: progress))
        assert(WindowsLaunchProgress.afterFirstFrame(current: progress, wineRunning: false) == 90)
        assert(WindowsLaunchProgress.afterFirstFrame(current: progress, wineRunning: true) == 100)
        assert(!WindowsLaunchProgress.shouldDisplay(status: "Running", percentage: 100))
        assert(WindowsLaunchProgress.advance(current: 70, status: "Preparing Wine prefix...") == 70)
        assert(WindowsLaunchProgress.advance(current: 40, status: "Execution Error: missing DLL") == 40)
        assert(WindowsLaunchProgress.advance(current: 0, status: "Unrecognized") == 0)
        print("PASS: Wine initialization progress only reaches 100% after observed Metal frames")
    }
}
