import Foundation
import UIKit

/// A project whose releases iDeck keeps an eye on.
struct TrackedProject: Identifiable {
    let id: String
    let name: String
    let owner: String
    let repo: String
}

struct ProjectStatus: Identifiable {
    let project: TrackedProject
    /// Tag of the newest release that has an .ipa attached.
    var latest: String?
    var failed = false
    var ipaURL: URL?
    var pageURL: URL?
    var id: String { project.id }
}

/// Reads the newest GitHub release that ships an IPA for each tracked project. Native code cannot be
/// swapped inside an installed app, so "installing" an update means installing a newer iDeck IPA over
/// the current one through a sideloading app, which keeps the app's data.
@MainActor
final class UpdateChecker: ObservableObject {
    static let ideck = TrackedProject(id: "ideck", name: "iDeck", owner: "FacensPedro", repo: "iDeck")

    static let projects: [TrackedProject] = [
        ideck,
        TrackedProject(id: "stikdebug", name: "StikDebug", owner: "StikDebug", repo: "StikDebug"),
        TrackedProject(id: "livecontainer", name: "LiveContainer", owner: "LiveContainer", repo: "LiveContainer"),
        TrackedProject(id: "madeira", name: "Madeira", owner: "willfaust", repo: "madeira")
    ]

    @Published var statuses: [ProjectStatus] = UpdateChecker.projects.map { ProjectStatus(project: $0) }
    @Published var isChecking = false
    @Published var hasChecked = false
    @Published private(set) var installHandoffMessage: String?

    /// Version of the installed iDeck.
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
        guard !isChecking else { return }
        isChecking = true
        installHandoffMessage = nil
        var result: [ProjectStatus] = []
        for project in Self.projects {
            result.append(await fetch(project))
        }
        statuses = result
        isChecking = false
        hasChecked = true
    }

    /// Open a signed update in the user's existing sideloading app. iOS does
    /// not allow this process to overwrite its own code or skip resigning.
    /// Opening the installer is not confirmation that an update was installed.
    func installIDeckUpdate() {
        guard let status = availableIDeckUpdate,
              let ipa = status.ipaURL,
              ipa.scheme == "https",
              ipa.host?.lowercased() == "github.com",
              ipa.path.hasPrefix("/FacensPedro/iDeck/releases/download/") else {
            installHandoffMessage = "No verified iDeck IPA release is available."
            return
        }

        let candidates = ["sidestore", "altstore"].compactMap { scheme -> URL? in
            var parts = URLComponents()
            parts.scheme = scheme
            parts.host = "install"
            parts.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
            return parts.url
        }

        func attempt(_ index: Int) {
            guard index < candidates.count else {
                installHandoffMessage = "SideStore or AltStore is required to install the signed update. Opening GitHub Releases instead."
                if let page = status.pageURL {
                    UIApplication.shared.open(page)
                } else if let page = URL(string: "https://github.com/FacensPedro/iDeck/releases") {
                    UIApplication.shared.open(page)
                }
                return
            }
            UIApplication.shared.open(candidates[index], options: [:]) { [weak self] opened in
                guard let self else { return }
                if opened {
                    self.installHandoffMessage = "The update was sent to the installer. Complete the installation there; iDeck cannot replace itself."
                } else {
                    attempt(index + 1)
                }
            }
        }
        attempt(0)
    }

    func openIDeckReleases() {
        guard let page = URL(string: "https://github.com/FacensPedro/iDeck/releases") else { return }
        UIApplication.shared.open(page)
    }

    // MARK: Networking

    private func fetch(_ project: TrackedProject) async -> ProjectStatus {
        var status = ProjectStatus(project: project)
        guard let url = URL(string: "https://api.github.com/repos/\(project.owner)/\(project.repo)/releases?per_page=30") else {
            status.failed = true
            return status
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            // GitHub lists releases newest first; take the first published one that carries an IPA.
            for release in releases where !release.draft {
                if let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }),
                   let ipa = URL(string: asset.browser_download_url),
                   ipa.scheme == "https",
                   ipa.host?.lowercased() == "github.com",
                   ipa.path.hasPrefix("/\(project.owner)/\(project.repo)/releases/download/"),
                   let page = URL(string: release.html_url),
                   page.scheme == "https",
                   page.host?.lowercased() == "github.com" {
                    status.latest = release.tag_name
                    status.ipaURL = ipa
                    status.pageURL = page
                    break
                }
            }
        } catch {
            status.failed = true
        }
        return status
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let draft: Bool
        let assets: [Asset]
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
