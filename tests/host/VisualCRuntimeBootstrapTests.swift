import Foundation

@main
struct VisualCRuntimeBootstrapTests {
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ideck-vc-runtime-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let prefix = temporary.appendingPathComponent("prefix", isDirectory: true)
        let documents = temporary.appendingPathComponent("Documents", isDirectory: true)
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let userDLLs = documents.appendingPathComponent("vcruntime", isDirectory: true)
        try FileManager.default.createDirectory(at: userDLLs, withIntermediateDirectories: true)

        assert(!VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))
        assert(!VisualCRuntimeBootstrap.complete(in: prefix))
        assert(!VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))

        var mockPE = Data(repeating: 0, count: 128)
        mockPE[0] = 0x4D
        mockPE[1] = 0x5A
        mockPE[0x3C] = 0x40
        mockPE[0x40] = 0x50
        mockPE[0x41] = 0x45
        mockPE[0x44] = 0x64
        mockPE[0x45] = 0x86
        assert(VisualCRuntimeBootstrap.hasPE({
            let candidate = temporary.appendingPathComponent("sample.dll")
            try! mockPE.write(to: candidate)
            return candidate
        }()))
        assert(!VisualCRuntimeBootstrap.hasPE(temporary.appendingPathComponent("missing.dll")))
        try mockPE.write(to: system32.appendingPathComponent("vcruntime140.dll"))
        assert(!VisualCRuntimeBootstrap.complete(in: prefix))
        try mockPE.write(to: system32.appendingPathComponent("msvcp140.dll"))
        assert(VisualCRuntimeBootstrap.complete(in: prefix))
        assert(VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))

        try FileManager.default.removeItem(at: system32.appendingPathComponent("msvcp140.dll"))
        assert(!VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))
        try mockPE.write(to: userDLLs.appendingPathComponent("vcruntime140.dll"))
        try mockPE.write(to: userDLLs.appendingPathComponent("msvcp140.dll"))
        assert(VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))

        var x86PE = mockPE
        x86PE[0x44] = 0x4C
        x86PE[0x45] = 0x01
        let x86URL = temporary.appendingPathComponent("x86.exe")
        try x86PE.write(to: x86URL)
        assert(!VisualCRuntimeBootstrap.hasPE(x86URL))
        assert(VisualCRuntimeBootstrap.hasPE(x86URL, machines: [0x014C, 0x8664]))
        assert(VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!))
        assert(VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://download.visualstudio.microsoft.com/download/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "http://download.microsoft.com/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://download.microsoft.com.evil.test/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://example.com/vc_redist.x64.exe")!))
        print("PASS: Visual C++ first-run marker and trusted official endpoints")
    }
}
