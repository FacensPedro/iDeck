#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AppLog { static func record(_ text: String) {} }
enum WineMonoInstaller {
    static func sha256(of url: URL) throws -> String { "unused" }
    static func unpack(tarXZ: URL, into: URL, map: (String) -> String?, progress: (Int64) -> Void) throws {}
}
enum ObservedDownload {
    struct Failure: Error { let error: Error; let resumeData: Data? }
    static var calls = 0
    static var resumed = false
    static func megabytes(_ n: Int64) -> String { String(n) }
    static func run(_ request: URLRequest, resumeData: Data?, expected: Int64,
                    progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse) {
        calls += 1
        if calls == 1 { throw Failure(error: URLError(.networkConnectionLost), resumeData: Data([1])) }
        resumed = resumeData != nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("complete resumed archive".utf8).write(to: url)
        return (url, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!)
    }
}
extension MadeiraRuntime {
    static func testResume() async throws {
        let archive = try await download(packages[0]) { _, _ in }
        defer { try? FileManager.default.removeItem(at: archive) }
        precondition(ObservedDownload.resumed && ObservedDownload.calls == 2)
        precondition(try! String(contentsOf: archive, encoding: .utf8) == "complete resumed archive")
    }
}

@main struct RuntimeRecoveryTests {
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        MadeiraRuntime.root = base.appendingPathComponent("runtime")
        MadeiraRuntime.packages = [.init(id: "wine-x64", title: "x64", url: URL(string: "https://example.invalid/runtime")!, sha256: "digest", bytes: 20)]
        for (name, machines) in MadeiraRuntime.requiredFiles["wine-x64"]! {
            let file = MadeiraRuntime.root.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var bytes = Data(repeating: 0, count: machines.isEmpty ? 4097 : 128)
            if let machine = machines.first {
                bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[0x3c] = 64
                bytes[64] = 0x50; bytes[65] = 0x45
                bytes[68] = UInt8(machine & 255); bytes[69] = UInt8(machine >> 8)
            }
            try bytes.write(to: file)
        }
        try "digest".write(to: MadeiraRuntime.root.appendingPathComponent(".installed-wine-x64"), atomically: true, encoding: .utf8)
        precondition(MadeiraRuntime.installed("wine-x64"))
        try fm.removeItem(at: MadeiraRuntime.root.appendingPathComponent("arm64ec-windows/kernel32.dll"))
        precondition(!MadeiraRuntime.installed("wine-x64") && MadeiraRuntime.needsDownload)
        try await MadeiraRuntime.testResume()

        enum Injected: Error { case move }
        // Fail each old/new folder move in turn; the prior runtime must survive.
        for failure in 1...4 {
            let root = base.appendingPathComponent("failure-\(failure)")
            let stage = base.appendingPathComponent("stage-\(failure)")
            for folder in ["arm64ec-windows", "nls"] {
                for (directory, text) in [(root, "old"), (stage, "new")] {
                    let dir = directory.appendingPathComponent(folder)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try text.write(to: dir.appendingPathComponent("file"), atomically: true, encoding: .utf8)
                }
            }
            let marker = root.appendingPathComponent(".installed-wine-x64")
            try "old-digest".write(to: marker, atomically: true, encoding: .utf8)
            var moves = 0
            do {
                try RuntimePackageTransaction.commit(root: root, staging: stage, id: "wine-x64", digest: "new-digest",
                    folders: ["arm64ec-windows", "nls"], move: { from, to in
                        moves += 1
                        if moves == failure { throw Injected.move }
                        try fm.moveItem(at: from, to: to)
                    })
                preconditionFailure("Injected failure was ignored")
            } catch Injected.move {}
            for folder in ["arm64ec-windows", "nls"] {
                precondition(try! String(contentsOf: root.appendingPathComponent(folder + "/file"), encoding: .utf8) == "old")
            }
            precondition(try! String(contentsOf: marker, encoding: .utf8) == "old-digest")
        }
        // Simulate termination after one replacement, then recover on next launch.
        let root = base.appendingPathComponent("interrupted")
        let transaction = RuntimePackageTransaction.directory(root: root, id: "wine-x64")
        try fm.createDirectory(at: transaction.appendingPathComponent("previous/nls"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("nls"), withIntermediateDirectories: true)
        try "old".write(to: transaction.appendingPathComponent("previous/nls/file"), atomically: true, encoding: .utf8)
        try "new".write(to: root.appendingPathComponent("nls/file"), atomically: true, encoding: .utf8)
        let journal: [String: Any] = ["digest": "new", "folders": ["nls"], "previousFolders": ["nls"], "previousMarker": "old"]
        try JSONSerialization.data(withJSONObject: journal).write(to: transaction.appendingPathComponent("journal.json"))
        try RuntimePackageTransaction.recover(root: root, id: "wine-x64")
        precondition(try! String(contentsOf: root.appendingPathComponent("nls/file"), encoding: .utf8) == "old")
        precondition(!fm.fileExists(atPath: transaction.path))

        let stage = base.appendingPathComponent("success-stage/nls")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try "new".write(to: stage.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try RuntimePackageTransaction.commit(root: root, staging: stage.deletingLastPathComponent(), id: "wine-x64", digest: "new", folders: ["nls"])
        precondition(try! String(contentsOf: root.appendingPathComponent("nls/file"), encoding: .utf8) == "new")
        precondition(try! String(contentsOf: root.appendingPathComponent(".installed-wine-x64"), encoding: .utf8) == "new")
        print("PASS: missing DLL repair, HTTP 206 resume, rollback at every move, interrupted recovery, successful commit")
    }
}
