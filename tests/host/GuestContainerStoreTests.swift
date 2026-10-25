import Foundation

@main struct GuestContainerStoreTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GuestContainerStore(root: root)
        let first = try store.create(for: "com.example.one", name: "Primary")
        let second = try store.create(for: "com.example.one", name: "Second")
        let other = try store.create(for: "com.example.two", name: "Primary")
        let file = root.appendingPathComponent(first.id.uuidString + "/Documents/save.txt")
        try Data("save".utf8).write(to: file)
        try store.select(first.id, for: "com.example.one")
        try store.rename(first.id, for: "com.example.one", name: "Renamed")
        let reopened = GuestContainerStore(root: root)
        let selection = try reopened.selection(for: "com.example.one")
        precondition(selection.selected == first.id)
        precondition(selection.containers.first?.name == "Renamed")
        precondition(tryRead(file) == "save")
        do {
            try store.remove(other.id, for: "com.example.one")
            fatalError("Cross-app removal was accepted")
        } catch is CocoaError { }
        try store.remove(first.id, for: "com.example.one")
        let afterDelete = try store.selection(for: "com.example.one")
        precondition(afterDelete.selected == second.id)
        precondition(!FileManager.default.fileExists(atPath: file.path))
        let otherSelection = try store.selection(for: "com.example.two")
        precondition(otherSelection.containers == [other])
        try Data("invalid manifest".utf8).write(to: root.appendingPathComponent("containers.json"))
        do {
            try store.create(for: "com.example.three", name: "New")
            fatalError("Corrupt manifest was overwritten")
        } catch is DecodingError { }
        print("Guest container persistence, selection and deletion checks passed")
    }
    static func tryRead(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
}
