import Foundation

@main
struct VisualCRuntimeBootstrapTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ideck-vcruntime-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let runtime = documents.appendingPathComponent("vcruntime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        assert(!VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))

        var pe = Data(repeating: 0, count: 512)
        pe[0] = 0x4D
        pe[1] = 0x5A
        pe[0x3C] = 0x80
        pe[0x80] = 0x50
        pe[0x81] = 0x45
        pe[0x84] = 0x64
        pe[0x85] = 0x86
        pe[0x98] = 0x0B
        pe[0x99] = 0x02
        pe[0x98 + 108] = 16
        pe[0x98 + 112 + 32] = 0x80
        pe[0x98 + 112 + 33] = 0x01
        pe[0x98 + 112 + 36] = 0x10
        let first = runtime.appendingPathComponent(VisualCRuntimeBootstrap.requiredDLLs[0])
        try pe.write(to: first)
        assert(VisualCRuntimeBootstrap.hasPE(first))
        assert(ideck_vcrt_valid_pe_x64(first.path) != 0)
        assert(!VisualCRuntimeBootstrap.hasCompleteRuntime(in: runtime))
        for dll in VisualCRuntimeBootstrap.requiredDLLs.dropFirst() {
            try pe.write(to: runtime.appendingPathComponent(dll))
        }
        assert(VisualCRuntimeBootstrap.hasCompleteRuntime(in: runtime))
        assert(VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))

        var x86 = pe
        x86[0x84] = 0x4C
        x86[0x85] = 0x01
        try x86.write(to: first)
        assert(ideck_vcrt_valid_pe_x64(first.path) == 0)
        assert(!VisualCRuntimeBootstrap.installed(in: prefix, documents: documents))
        assert(VisualCRuntimeBootstrap.hasPE(first, machines: [0x014C, 0x8664]))
        assert(!VisualCRuntimeBootstrap.hasPE(first))
        try pe.write(to: first)
        pe[0x98 + 112 + 32] = 0
        try pe.write(to: first)
        assert(ideck_vcrt_valid_pe_x64(first.path) == 0)

        assert(VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://aka.ms/vc14/vc_redist.x64.exe")!))
        assert(VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://download.visualstudio.microsoft.com/download/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "http://download.microsoft.com/example")!))
        assert(!VisualCRuntimeBootstrap.isTrustedDownloadURL(URL(string: "https://download.microsoft.com.evil.test/example")!))
        print("PASS: PE x64 and certificate-table checks, full 14-DLL installation state")
    }
}
