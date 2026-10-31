import SwiftUI

/// A titled group on a game's details page: a rounded panel whose rows are
/// separated by thin dividers, like a grouped list.
struct DetailCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.gray)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a DetailCard: a label on the left, a control or value on the right.
struct DetailRow<Trailing: View>: View {
    let title: String
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundColor(.white)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: 46)
            .padding(.horizontal, 14)
            if showsDivider {
                Divider().background(Color.white.opacity(0.08)).padding(.leading, 14)
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

    var body: some View {
        DetailRow(title: title, showsDivider: showsDivider) {
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

    var body: some View {
        DetailRow(title: title, showsDivider: showsDivider) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(.blue)
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
