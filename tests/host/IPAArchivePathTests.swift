import Foundation

@main
struct IPAArchivePathTests {
    static func main() {
        let accepted = [
            "Payload/",
            "Payload/GetMoreRam.app/",
            "Payload/Husk.app/",
            "Payload/Husk.app/Info.plist",
            "Payload/Husk.app/Frameworks/Library.dylib",
            "Payload/GetMoreRam.app/Info.plist",
            "Payload/GetMoreRam.app/Frameworks/../Info.plist",
            "Payload\\GetMoreRam.app\\Frameworks\\foo.dylib",
            "Payload/My App.app/_CodeSignature/CodeResources"
        ]
        let rejected = [
            "/Payload/X.app/Info.plist",
            "Payload/X.app/../../escape",
            "Payload/X.app/../Else.app/Info.plist",
            "Payload/X.app/../../../escape",
            "Payload/Info.plist",
            "Payload/.app/Info.plist",
            "Payload/X.app/C:/x",
            "Payload/X.app/\u{0}bad",
            "Payload/X.app/\nfile",
            "../Payload/X.app/Info.plist"
        ]
        for path in accepted {
            precondition(IPAArchivePath.components(path) != nil, "Valid IPA entry rejected: \(path)")
        }
        for path in rejected {
            precondition(IPAArchivePath.components(path) == nil, "Unsafe IPA entry accepted: \(path)")
        }
        precondition(IPAArchivePath.isDirectory("Payload/GetMoreRam.app/", unixMode: 0))
        precondition(IPAArchivePath.components("Payload/Husk.app/") == ["Payload", "Husk.app"])
        precondition(IPAArchivePath.isDirectory("Payload/Husk.app/", unixMode: 0))
        precondition(IPAArchivePath.isDirectory("Payload/GetMoreRam.app", unixMode: 0o040755))
        precondition(!IPAArchivePath.isDirectory("Payload/GetMoreRam.app/Info.plist", unixMode: 0o100644))
        print("IPA archive path checks passed")
    }
}
