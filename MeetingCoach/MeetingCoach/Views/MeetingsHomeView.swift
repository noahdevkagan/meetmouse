import SwiftUI

/// The front door: what needs attention across saved meetings (open
/// follow-ups, notes to review, meetings without notes) plus ask-across
/// search. The meeting list itself lives in the sidebar, not repeated here.
/// Everything is read from the saved files; no statuses or second store.
struct MeetingsHomeView: View {
    var liveSession: LiveSessionViewModel
    var settings: SettingsViewModel
    var refreshKey: String?
    var onOpen: (URL) -> Void
    var onSearch: (String) -> Void
    @State private var hasMeetings = false
    @State private var loaded = false
    @State private var attention = MeetingNotesFile.Attention()
    @State private var showAllFollowUps = false
    @State private var question = ""
    @State private var showingSharedLinks = false
    @State private var reloadTick = 0

    private static let followUpPreview = 5
    private static let statusPreview = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(greeting).font(.system(size: 30, weight: .semibold))
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                }

                if loaded && (!hasMeetings || DebugPreview.active) {
                    // A new person's first screen: setup lives here.
                    OnboardingChecklistView(liveSession: liveSession, settings: settings)
                }
                if loaded && hasMeetings {
                    if settings.hasCheckedModels, !settings.aiReady { AISetupCard(settings: settings) }
                    if !attention.followUps.isEmpty { followUpsSection }
                    if !attention.statuses.isEmpty { statusSection }
                    if attention.isEmpty {
                        Label("You're all caught up. Open follow-ups and new notes show up here.",
                              systemImage: "checkmark.circle")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Ask across your meetings")
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
                }

                Button { showingSharedLinks = true } label: {
                    Label("Shared links", systemImage: "link")
                }
                .buttonStyle(DoradoOutlineButtonStyle())
                .sheet(isPresented: $showingSharedLinks) { SharedLinksManagerView() }
                Label(settings.usesCloudAI
                      ? "Your transcripts stay on this Mac. AI features send meeting text to \(settings.aiConfiguration.provider.title)."
                      : "Your transcripts and AI conversations stay on this Mac", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
            .padding(36)
        }
        .background(Dorado.surface)
        .task(id: "\(refreshKey ?? "")#\(reloadTick)") { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didDeleteMeeting)) { _ in
            reloadTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptSearch.didChangeTitle)) { _ in
            reloadTick += 1
        }
    }

    // MARK: Sections

    private var followUpsSection: some View {
        let items = showAllFollowUps ? attention.followUps
            : Array(attention.followUps.prefix(Self.followUpPreview))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Open follow-ups")
                Text("from your meeting notes").font(.caption).foregroundStyle(.tertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider() }
                    followUpRow(item)
                }
                if attention.followUps.count > Self.followUpPreview {
                    Divider()
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showAllFollowUps.toggle() }
                    } label: {
                        Text(showAllFollowUps ? "Show fewer" : "Show all \(attention.followUps.count)")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 11).padding(.horizontal, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardStyle(cornerRadius: 12)
        }
    }

    private func followUpRow(_ item: MeetingNotesFile.FollowUp) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                if MeetingNotesFile.setDone(item, true) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        attention.followUps.removeAll { $0.id == item.id }
                    }
                } else {
                    reloadTick += 1
                }
            } label: {
                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Mark done (ticks it in the meeting's notes)")
            .accessibilityLabel("Mark done: \(item.text)")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                Button { onOpen(item.url) } label: {
                    Text(meetingLine(item.meetingTitle, item.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open the meeting")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Recent meetings to look at")
            VStack(spacing: 0) {
                ForEach(Array(attention.statuses.prefix(Self.statusPreview).enumerated()),
                        id: \.element.id) { i, status in
                    if i > 0 { Divider() }
                    Button { onOpen(status.url) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(status.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(meetingLine(status.kind == .notesReady ? "Notes ready" : "No AI notes yet",
                                                 status.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(status.kind == .notesReady ? "Review notes" : "Generate notes")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(status.kind == .notesReady ? Dorado.dollar : .secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 11).padding(.horizontal, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .cardStyle(cornerRadius: 12)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
    }

    // MARK: Data

    private var greeting: String {
        guard loaded, hasMeetings else { return "Your meetings, in conversation" }
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    private var subtitle: String {
        guard loaded, hasMeetings else {
            return "Pick a meeting to ask questions, revisit decisions, and plan what comes next."
        }
        var parts: [String] = []
        let open = attention.followUps.count
        if open > 0 { parts.append(open == 1 ? "1 follow-up open" : "\(open) follow-ups open") }
        let ready = attention.statuses.filter { $0.kind == .notesReady }.count
        if ready > 0 { parts.append(ready == 1 ? "1 meeting's notes to review" : "\(ready) meetings' notes to review") }
        return parts.isEmpty ? "Nothing waiting on you." : parts.joined(separator: " · ")
    }

    private func meetingLine(_ lead: String, _ date: Date?) -> String {
        guard let date else { return lead }
        let day: String
        if Calendar.current.isDateInToday(date) { day = "Today" }
        else if Calendar.current.isDateInYesterday(date) { day = "Yesterday" }
        else { day = date.formatted(.dateTime.month(.abbreviated).day()) }
        return "\(lead) · \(day)"
    }

    private func reload() async {
        let opened = Set(UserDefaults.standard.stringArray(forKey: MeetingNotesFile.openedKey) ?? [])
        let (files, result) = await Task.detached(priority: .userInitiated) {
            let files = TranscriptSearch.sessionFiles()
            let result = MeetingNotesFile.attention(files: files, opened: opened) { url, content in
                TranscriptSearch.headerTitle(in: content) ?? TranscriptSearch.title(for: url)
            }
            return (files, result)
        }.value
        guard !Task.isCancelled else { return }
        hasMeetings = !files.isEmpty
        attention = result
        loaded = true
    }

    private func search() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2 { onSearch(text) }
    }
}
