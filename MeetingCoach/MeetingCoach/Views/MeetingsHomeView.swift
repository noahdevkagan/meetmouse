import SwiftUI

/// Meeting history is the front door; coaching progress remains a secondary destination.
struct MeetingsHomeView: View {
    var refreshKey: String?
    var onOpen: (URL) -> Void
    var onSearch: (String) -> Void
    @State private var meetings: [URL] = []
    @State private var question = ""
    @State private var showingSharedLinks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your meetings, in conversation")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Pick a meeting to ask questions, revisit decisions, and plan what comes next.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search or ask across your meetings…", text: $question)
                        .textFieldStyle(.plain).onSubmit(search)
                    Button(action: search) {
                        Image(systemName: "arrow.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    .accessibilityLabel("Search meetings")
                }
                .padding(16).cardStyle(cornerRadius: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent meetings").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).padding(.bottom, 10)
                    if meetings.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Start with your next conversation")
                                .font(.system(size: 20, weight: .medium))
                            Text("Start a meeting from the sidebar. Your transcript saves here, ready to chat with afterward.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    ForEach(meetings, id: \.self) { url in
                        Button { onOpen(url) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .foregroundStyle(Dorado.dollar)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(TranscriptSearch.headerTitle(at: url) ?? TranscriptSearch.title(for: url))
                                        .font(.system(size: 16, weight: .medium)).lineLimit(2)
                                    Text(TranscriptSearch.shortDate(for: url) ?? "Saved meeting")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 16).padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                Button { showingSharedLinks = true } label: {
                    Label("Shared links", systemImage: "link")
                }
                .buttonStyle(DoradoOutlineButtonStyle())
                .sheet(isPresented: $showingSharedLinks) { SharedLinksManagerView() }
                Label("Your transcripts and AI conversations stay on this Mac", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
            .padding(36)
        }
        .background(Dorado.surface)
        .task(id: refreshKey) { meetings = Array(TranscriptSearch.sessionFiles().prefix(30)) }
    }

    private func search() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2 { onSearch(text) }
    }
}
