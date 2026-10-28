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

        let mockPE = Data([0x4D, 0x5A, 0x01, 0x02])
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

        assert(VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!))
        assert(VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://download.visualstudio.microsoft.com/download/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "http://download.microsoft.com/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://download.microsoft.com.evil.test/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://example.com/vc_redist.x64.exe")!))
        print("PASS: Visual C++ first-run marker and trusted official endpoints")
    }
}
