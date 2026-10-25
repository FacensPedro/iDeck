import Foundation

enum GuestContainerValidationError: LocalizedError {
    case invalidAppIdentifier
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidAppIdentifier:
            return "The app identifier must not be empty."
        case .invalidName:
            return "The container name must contain between 1 and 80 characters."
        }
    }
}

struct GuestDataContainer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
}

struct GuestContainerSelection: Codable {
    var containers: [GuestDataContainer] = []
    var selected: UUID?
}

final class GuestContainerStore {
    static let shared = GuestContainerStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iDeck/GuestContainers", isDirectory: true))
    private let root: URL
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default

    init(root: URL) { self.root = root }

    private func read() throws -> [String: GuestContainerSelection] {
        let manifest = root.appendingPathComponent("containers.json")
        guard fm.fileExists(atPath: manifest.path) else { return [:] }
        return try JSONDecoder().decode([String: GuestContainerSelection].self, from: Data(contentsOf: manifest))
    }

    private func save(_ state: [String: GuestContainerSelection]) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("containers.json"), options: .atomic)
    }

    func selection(for app: String) throws -> GuestContainerSelection {
        lock.lock(); defer { lock.unlock() }
        return try read()[app] ?? GuestContainerSelection()
    }

    @discardableResult
    func create(for app: String, name: String) throws -> GuestDataContainer {
        lock.lock(); defer { lock.unlock() }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GuestContainerValidationError.invalidAppIdentifier }
        guard !cleanName.isEmpty, cleanName.count <= 80 else { throw GuestContainerValidationError.invalidName }
        var state = try read()
        var selection = state[app] ?? GuestContainerSelection()
        let container = GuestDataContainer(id: UUID(), name: cleanName)
        let directory = root.appendingPathComponent(container.id.uuidString, isDirectory: true)
        do {
            for folder in ["Documents", "Library/Preferences", "Library/Caches", "tmp"] {
                try fm.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            selection.containers.append(container)
            selection.selected = container.id
            state[app] = selection
            try save(state)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
        return container
    }

    func select(_ id: UUID, for app: String) throws {
        lock.lock(); defer { lock.unlock() }
        var state = try read()
        guard var selection = state[app], selection.containers.contains(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        selection.selected = id
        state[app] = selection
        try save(state)
    }

    func rename(_ id: UUID, for app: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 80 else { throw GuestContainerValidationError.invalidName }
        var state = try read()
        guard var selection = state[app], let index = selection.containers.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        selection.containers[index].name = cleanName
        state[app] = selection
        try save(state)
    }

    func remove(_ id: UUID, for app: String) throws {
        lock.lock(); defer { lock.unlock() }
        var state = try read()
        guard var selection = state[app], selection.containers.contains(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let trash = root.appendingPathComponent("removed-" + UUID().uuidString, isDirectory: true)
        let exists = fm.fileExists(atPath: directory.path)
        if exists { try fm.moveItem(at: directory, to: trash) }
        selection.containers.removeAll { $0.id == id }
        if selection.selected == id { selection.selected = selection.containers.first?.id }
        state[app] = selection
        do { try save(state) }
        catch {
            if exists { try? fm.moveItem(at: trash, to: directory) }
            throw error
        }
        if exists { try fm.removeItem(at: trash) }
    }
}
