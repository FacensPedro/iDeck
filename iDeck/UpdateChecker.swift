import Foundation
import UIKit

/// A project whose releases iDeck keeps an eye on.
struct TrackedProject: Identifiable {
    let id: String
    let name: String
    let owner: String
    let repo: String
    /// Release tag or short commit iDeck was built against; nil when not tracked yet.
    let pinnedVersion: String?
}

struct ProjectStatus: Identifiable {
    let project: TrackedProject
    var latest: String?
    var error: String?
    var ipaURL: URL?
    var pageURL: URL?
    var id: String { project.id }

    /// True when upstream moved past the version iDeck is based on.
    var upstreamChanged: Bool {
        guard let latest = latest, let pinned = project.pinnedVersion else { return false }
        return latest != pinned
    }
}

/// Checks GitHub for newer releases. Native code cannot be swapped inside an installed app, so
/// "installing" an update means installing a newer iDeck IPA (built by CI with the newer upstream
/// code) over the current one through a sideloading app, which keeps the app's data.
@MainActor
final class UpdateChecker: ObservableObject {
    static let ideck = TrackedProject(id: "ideck", name: "iDeck", owner: "FacensPedro", repo: "iDeck", pinnedVersion: nil)

    static let projects: [TrackedProject] = [
        ideck,
        TrackedProject(id: "stikdebug", name: "StikDebug", owner: "StikDebug", repo: "StikDebug", pinnedVersion: nil),
        TrackedProject(id: "livecontainer", name: "LiveContainer", owner: "LiveContainer", repo: "LiveContainer", pinnedVersion: nil),
        TrackedProject(id: "madeira", name: "Madeira", owner: "willfaust", repo: "madeira", pinnedVersion: "279fd0f")
    ]

    @Published var statuses: [ProjectStatus] = UpdateChecker.projects.map { ProjectStatus(project: $0) }
    @Published var isChecking = false
    @Published var message: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A newer iDeck release with an IPA attached, if any.
    var availableIDeckUpdate: ProjectStatus? {
        guard let status = statuses.first(where: { $0.project.id == Self.ideck.id }),
              let latest = status.latest, status.ipaURL != nil,
              Self.isNewer(latest, than: currentVersion) else { return nil }
        return status
    }

    func check() async {
        isChecking = true
        message = nil
        var result: [ProjectStatus] = []
        for project in Self.projects {
            result.append(await fetch(project))
        }
        statuses = result
        isChecking = false
        if availableIDeckUpdate == nil && !result.contains(where: { $0.upstreamChanged }) {
            message = "Everything is up to date."
        }
    }

    /// Hands the new IPA to AltStore or SideStore (installs over the current app, data is kept).
    /// Falls back to the release page when neither app is installed.
    func installIDeckUpdate() {
        guard let status = availableIDeckUpdate, let ipa = status.ipaURL else { return }
        let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ipa.absoluteString
        let candidates = ["sidestore://install?url=\(encoded)", "altstore://install?url=\(encoded)"].compactMap(URL.init(string:))

        func attempt(_ index: Int) {
            guard index < candidates.count else {
                if let page = status.pageURL { UIApplication.shared.open(page) }
                return
            }
            UIApplication.shared.open(candidates[index], options: [:]) { opened in
                if !opened { attempt(index + 1) }
            }
        }
        attempt(0)
    }

    // MARK: Networking

    private func fetch(_ project: TrackedProject) async -> ProjectStatus {
        var status = ProjectStatus(project: project)
        let base = "https://api.github.com/repos/\(project.owner)/\(project.repo)"

        do {
            if let release: Release = try await get("\(base)/releases/latest", allowNotFound: true) {
                status.latest = release.tag_name
                status.pageURL = URL(string: release.html_url)
                status.ipaURL = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") })
                    .flatMap { URL(string: $0.browser_download_url) }
            } else if let commits: [Commit] = try await get("\(base)/commits?per_page=1", allowNotFound: false),
                      let first = commits.first {
                status.latest = String(first.sha.prefix(7))
                status.pageURL = URL(string: first.html_url)
            }
        } catch {
            status.error = error.localizedDescription
        }
        return status
    }

    private func get<T: Decodable>(_ urlString: String, allowNotFound: Bool) async throws -> T? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 && allowNotFound { return nil }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let assets: [Asset]
    }

    private struct Commit: Decodable {
        let sha: String
        let html_url: String
    }

    /// Compares dotted numeric versions ("v1.2.10" > "1.2.9"); non-numeric parts are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
