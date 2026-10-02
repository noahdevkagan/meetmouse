import SwiftUI

/// The one language menu every quick control shares (sidebar chip,
/// detection pill, live header): Auto-detect, then the user's recent
/// languages, then all 25. Multilingual users switch between the same few,
/// so those stay one click away.
struct MeetingLanguageMenuItems: View {
    /// The language currently in effect — checked in the menu.
    let current: MeetingLanguageSelection
    let onSelect: (MeetingLanguageSelection) -> Void

    private var quick: [MeetingLanguageSelection] {
        var list = MeetingLanguageSelection.recent()
        if current.isSpecific, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    var body: some View {
        item(.auto)
        Divider()
        Section("Recent") {
            ForEach(quick) { item($0) }
        }
        Divider()
        Menu("All languages") {
            ForEach(MeetingLanguageSelection.specificLanguages) { item($0) }
        }
    }

    private func item(_ language: MeetingLanguageSelection) -> some View {
        Toggle(language.pickerName, isOn: Binding(
            get: { current == language },
            set: { _ in onSelect(language) }))
    }
}

/// A small capsule that opens the shared language menu.
struct MeetingLanguageChip: View {
    let title: String
    let current: MeetingLanguageSelection
    var highlighted = false
    let onSelect: (MeetingLanguageSelection) -> Void

    var body: some View {
        Menu {
            MeetingLanguageMenuItems(current: current, onSelect: onSelect)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Dorado.grey500)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Dorado.grey800)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(highlighted ? Dorado.doradoTint : Dorado.surfaceSubtle, in: Capsule())
            .overlay(Capsule().strokeBorder(highlighted ? Dorado.dollar.opacity(0.35) : Dorado.border))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Meeting language")
        .accessibilityLabel("Meeting language: \(title)")
    }
}
