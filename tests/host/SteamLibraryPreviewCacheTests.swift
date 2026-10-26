import Foundation

@main
struct SteamLibraryPreviewCacheTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ideck-steam-library-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let preview = SteamLibraryCachedGame(
            appID: 440, name: "Example Game", type: "Game",
            installDir: "Example", oslist: "windows", buildID: 123,
            libraryCapsule: "capsule.jpg", libraryHero: "hero.jpg",
            headerImage: "header.jpg", parentID: nil)
        let games = [preview]

        assert(SteamLibraryPreviewCache.save(
            account: "AccountA", games: games, directory: root, now: now))
        assert(SteamLibraryPreviewCache.load(
            account: "AccountA", directory: root, now: now) == games)
        assert(SteamLibraryPreviewCache.load(
            account: "AccountB", directory: root, now: now) == nil)
        assert(SteamLibraryPreviewCache.load(
            account: "AccountA", directory: root,
            now: now.addingTimeInterval(8 * 24 * 3600)) == nil)
        assert(SteamLibraryPreviewCache.load(
            account: "AccountA", directory: root,
            now: now.addingTimeInterval(-60)) == nil)

        let contents = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("iDeckSteamLibrary"), includingPropertiesForKeys: nil)
        assert(contents.count == 1)
        assert(!contents[0].lastPathComponent.contains("AccountA"))
        let data = try Data(contentsOf: contents[0])
        assert(!data.contains(Data("accessToken".utf8)))
        assert(!data.contains(Data("refreshToken".utf8)))

        SteamLibraryPreviewCache.remove(account: "AccountA", directory: root)
        assert(SteamLibraryPreviewCache.load(
            account: "AccountA", directory: root, now: now) == nil)
        assert(!SteamLibraryPreviewCache.save(
            account: "", games: games, directory: root, now: now))
        assert(!SteamLibraryPreviewCache.save(
            account: "AccountA", games: [], directory: root, now: now))

        assert(SteamLibraryPreviewCache.save(
            account: "AccountA", games: games, directory: root, now: now))
        let path = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("iDeckSteamLibrary"), includingPropertiesForKeys: nil).first!
        try Data("invalid JSON".utf8).write(to: path, options: .atomic)
        assert(SteamLibraryPreviewCache.load(
            account: "AccountA", directory: root, now: now) == nil)

        print("PASS: Steam library preview cache account isolation, TTL, and corruption checks")
    }
}
