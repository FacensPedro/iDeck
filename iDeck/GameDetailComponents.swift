import SwiftUI

/// A titled group on a game's details page, drawn like an inset grouped
/// section in Settings: a small header, rounded rows, an optional footer.
struct DetailCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.footnote)
                .foregroundColor(Color(white: 0.56))
                .padding(.horizontal, 16)
            VStack(spacing: 0) {
                content
            }
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundColor(Color(white: 0.56))
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The colored rounded-square icon used by Settings rows.
struct DetailIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// One row of a DetailCard: an optional icon and a label on the left, a
/// control or value on the right.
struct DetailRow<Trailing: View>: View {
    let title: String
    var showsDivider = true
    var icon: String? = nil
    var iconColor: Color = .gray
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon {
                    DetailIcon(systemImage: icon, color: iconColor)
                }
                Text(title)
                    .foregroundColor(.white)
                    .lineLimit(2)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
            if showsDivider {
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, icon == nil ? 16 : 56)
            }
        }
    }
}

/// A row with a menu picker of plain string choices.
struct DetailPickerRow: View {
    let title: String
    @Binding var selection: String
    let choices: [String]
    var showsDivider = true
    var icon: String? = nil
    var iconColor: Color = .gray

    var body: some View {
        DetailRow(title: title, showsDivider: showsDivider, icon: icon, iconColor: iconColor) {
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.self) { Text(tr($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(.gray)
            .labelsHidden()
        }
    }
}

/// A row with a switch.
struct DetailToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var showsDivider = true
    var icon: String? = nil
    var iconColor: Color = .gray

    var body: some View {
        DetailRow(title: title, showsDivider: showsDivider, icon: icon, iconColor: iconColor) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
    }
}

/// A row showing a read-only value, like LabeledContent in Settings.
struct DetailValueRow: View {
    let title: String
    let value: String
    var showsDivider = true
    var icon: String? = nil
    var iconColor: Color = .gray

    var body: some View {
        DetailRow(title: title, showsDivider: showsDivider, icon: icon, iconColor: iconColor) {
            Text(value)
                .foregroundColor(Color(white: 0.56))
                .lineLimit(1)
        }
    }
}

/// A full-width tappable row, like a Button inside a Settings Form.
struct DetailButtonRow: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var showsDivider = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(role: role, action: action) {
                HStack(spacing: 10) {
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                    Spacer()
                }
                .foregroundColor(role == .destructive ? .red : .blue)
                .frame(minHeight: 48)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsDivider {
                Divider().background(Color.white.opacity(0.08)).padding(.leading, 16)
            }
        }
    }
}

/// A small status capsule under a game's title.
struct DetailChip: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Steam achievements

/// A Steam game's achievements as the Steam store shows them: how many there are and
/// the ones Valve highlights, with their names (in iDeck's language when the game has
/// it) and icons. Read from the store's public app details, no account needed.
struct SteamAchievementSummary: Equatable {
    struct Item: Equatable { let name: String; let icon: URL? }
    let total: Int
    let highlighted: [Item]
}

actor SteamAchievementStore {
    static let shared = SteamAchievementStore()
    private var cache: [String: SteamAchievementSummary?] = [:]

    /// Steam's language name for iDeck's language.
    static var storeLanguage: String {
        switch AppLanguage.currentCode {
        case "pt": return "brazilian"
        case "es": return "latam"
        default: return "english"
        }
    }

    static func parse(_ data: Data, appID: UInt32) -> SteamAchievementSummary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appID)] as? [String: Any], entry["success"] as? Bool == true,
              let details = entry["data"] as? [String: Any],
              let achievements = details["achievements"] as? [String: Any],
              let total = (achievements["total"] as? NSNumber)?.intValue, total > 0 else { return nil }
        let items = (achievements["highlighted"] as? [[String: Any]] ?? []).compactMap { item -> SteamAchievementSummary.Item? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return .init(name: name, icon: (item["path"] as? String).flatMap(URL.init(string:)))
        }
        return SteamAchievementSummary(total: total, highlighted: items)
    }

    func summary(appID: UInt32) async -> SteamAchievementSummary? {
        let language = Self.storeLanguage
        let key = "\(appID)-\(language)"
        if let cached = cache[key] { return cached }
        var components = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        components.queryItems = [URLQueryItem(name: "appids", value: String(appID)),
                                 URLQueryItem(name: "filters", value: "achievements"),
                                 URLQueryItem(name: "l", value: language)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let summary = Self.parse(data, appID: appID)
        cache[key] = summary
        return summary
    }
}

/// The achievements card of a Steam game's page; hidden when the game has none.
struct SteamAchievementsCard: View {
    let appID: UInt32
    @State private var summary: SteamAchievementSummary?
    @State private var loaded = false

    var body: some View {
        Group {
            if let summary {
                DetailCard(title: tr("Achievements"),
                           footer: tr("%d achievements in this game. The highlighted ones are shown.", summary.total)) {
                    ForEach(Array(summary.highlighted.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 12) {
                            AsyncImage(url: item.icon) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(white: 0.2)
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(item.name)
                                .foregroundColor(.white)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 48)
                        .padding(.horizontal, 16)
                        if index < summary.highlighted.count - 1 {
                            Divider().background(Color.white.opacity(0.08)).padding(.leading, 60)
                        }
                    }
                    if summary.highlighted.isEmpty {
                        DetailRow(title: tr("%d achievements", summary.total), showsDivider: false) { EmptyView() }
                    }
                }
            }
        }
        .task(id: appID) {
            guard !loaded else { return }
            loaded = true
            summary = await SteamAchievementStore.shared.summary(appID: appID)
        }
    }
}
