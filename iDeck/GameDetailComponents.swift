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
