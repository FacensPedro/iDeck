import Foundation

// Build-time tool: downloads Microsoft's official Visual C++ redistributables
// (2005-2022, x86 and x64) and extracts their DLLs, without running them, into
// the layout iDeck reads from Documents/vcruntime (VisualCRuntimeBootstrap.swift,
// VisualCRuntimeLegacy). scripts/build_ipa.sh puts the result in the app as
// vcruntime-bundle, and iDeck copies it into place on first start: Visual C++
// is present without any install or download on the device.
//
// usage: vcrt-bundle <output folder>   (the folder becomes <output>/vcruntime)

setvbuf(stdout, nil, _IOLBF, 0)
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: vcrt-bundle <output folder>\n".utf8))
    exit(64)
}
let documents = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("vcrt-bundle: " + message + "\n").utf8))
    exit(1)
}

// 1. The x64 2015-2022 runtime.
let semaphore = DispatchSemaphore(value: 0)
var downloaded: Result<URL, Error>?
let prefix = documents.appendingPathComponent(".prefix", isDirectory: true)
VisualCRuntimeBootstrap.download(in: prefix) { downloaded = $0; semaphore.signal() }
while semaphore.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.current.run(until: Date() + 0.1) }
guard case .success(let installer)? = downloaded else { fail("x64 2015-2022 download failed") }
var extracted: Result<Void, Error>?
VisualCRuntimeBootstrap.extractAndInstall(installer: installer, documents: documents) { extracted = $0; semaphore.signal() }
while semaphore.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.current.run(until: Date() + 0.1) }
if case .failure(let error)? = extracted { fail("x64 2015-2022: \(error.localizedDescription)") }
try? FileManager.default.removeItem(at: prefix)
print("x64 2015-2022: ok")

// 2. 2005-2013 (x86 and x64) and the x86 2015-2022 runtime.
var failures: [String] = []
let done = DispatchSemaphore(value: 0)
Task {
    failures = await VisualCRuntimeLegacy.installAll(documents: documents) { print("extracting \($0)") }
    done.signal()
}
while done.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.current.run(until: Date() + 0.1) }
guard failures.isEmpty else { fail(failures.joined(separator: "; ")) }
let folder = documents.appendingPathComponent("vcruntime")
guard VisualCRuntimeBootstrap.hasCompleteRuntime(in: folder) else { fail("incomplete x64 runtime") }
print("Visual C++ runtime bundled in \(folder.path)")
