import SwiftUI
import AppKit

/// Saved-session viewer in the main pane: meta line + renameable title +
/// Copy/Export, and Transcript / Summary / Coaching tabs (Noah asked for
/// the tabs back, 2026-08-04). The markdown file on disk stays the
/// source of truth.
struct SessionDetailView: View {
    let url: URL
    /// Active search query — matched terms highlight in the transcript and
    /// the view scrolls to the first hit.
    var highlightQuery: String = ""
    /// Present = the Summary tab can (re)generate an AI review for this
    /// saved session — the escape hatch for sessions reviewed before a
    /// model was installed.
    var settings: SettingsViewModel?
    var ollamaManager: OllamaManager?
    var reviewRevision: MeetingReview? = nil
    var reviewInProgress = false
    let onClose: () -> Void

    enum Tab: String, CaseIterable {
        case chat = "Chat"
        case transcript = "Transcript"
        case summary = "Notes"
        case coaching = "Coaching"
    }

    @State private var confirmingDelete = false
    @State private var deleteError: String?
    @State private var title = ""
    @State private var metaLine = ""
    @State private var review: MeetingReview?
    @State private var lines: [(stamp: String, speaker: String, text: String)] = []
    @State private var nudgeLines: [String] = []
    @State private var rawContent = ""
    // Open saved meetings on Notes; search still opens the matching transcript.
    @State private var tab: Tab = .summary
    @State private var renaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var regenTick = 0
    @State private var regenerating = false
    @State private var durationMinutes = 0
    @State private var talkShareValue: Double?
    @State private var languageCode: String?
    // Completed turns persist in this meeting's local chat sidecar.
    // In-flight requests and drafts stay in memory; tab switches keep them intact.
    @State private var askThread: [MeetingChatTurn] = []
    @State private var chatLoadFailed = false
    @State private var chatSaveFailed = false
    @State private var confirmClearChat = false
    @State private var citedLine: Int?
    @State private var askInput = ""
    @State private var askBusy: String?
    @State private var pendingAsk: String?
    @State private var askTick = 0
    @State private var askError: String?
    @State private var sharedLink: SharedLinkRecord?
    @State private var showingShareSheet = false
    @State private var preparingShare = false
    @State private var confirmingStopShare = false
    @State private var revokingShare = false
    @State private var shareError: String?
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Dorado.surface)
        .task(id: url) {
            tab = highlightQuery.isEmpty ? .summary : .transcript
            askThread = []; askInput = ""; askBusy = nil; pendingAsk = nil
            load()
            do {
                askThread = try MeetingChatStore.load(for: url)
                chatLoadFailed = false
            } catch {
                chatLoadFailed = true
                askError = "Saved chat couldn't be read. Clear it to start over; your transcript is unchanged."
            }
            do {
                let record = try await SharedLinksStore.shared.record(for: url)
                guard !Task.isCancelled else { return }
                sharedLink = record
            } catch {
                guard !Task.isCancelled else { return }
                shareError = "Saved sharing controls couldn't be read: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: {
            Task {
                do { sharedLink = try await SharedLinksStore.shared.record(for: url) }
                catch { shareError = error.localizedDescription }
            }
        }) {
            if let review,
               let payload = SharedNotePayload.make(
                   title: title,
                   date: TranscriptSearch.sessionDate(for: url) ?? Date(),
                   durationMinutes: durationMinutes,
                   review: review
               ) {
                ShareNotesSheet(
                    sessionURL: url,
                    payload: payload
                ) { record in
                    sharedLink = record
                }
            }
        }
        .confirmationDialog("Delete “\(title)”?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) { deleteMeeting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the local transcript, notes, and saved chat. Shared links stay active; manage them in Meetings → Shared links.")
        }
        .alert("Couldn't delete meeting", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "Please try again.")
        }
        .confirmationDialog(
            "Stop sharing these notes?",
            isPresented: $confirmingStopShare,
            titleVisibility: .visible
        ) {
            Button("Stop sharing", role: .destructive) {
                guard let sharedLink else { return }
                Task { await stopSharing(sharedLink) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The private link will stop working. Your local meeting notes are not affected.")
        }
        .alert("Couldn't update sharing", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "Unknown error")
        }
        .confirmationDialog("Clear this meeting's saved chat?", isPresented: $confirmClearChat) {
            Button("Clear chat", role: .destructive) { clearChat() }
        } message: {
            Text("This removes the questions and answers. Your meeting transcript and notes stay saved.")
        }
        .onChange(of: tab) { _, _ in load() }
        .onChange(of: reviewRevision) { _, _ in load() }
        .onChange(of: reviewInProgress) { _, inProgress in
            load()
            if preparingShare && !inProgress && !regenerating { prepareShare() }
        }
        .task(id: regenTick) {
            guard regenTick > 0 else { return }
            await regenerateReview()
            guard !Task.isCancelled, preparingShare else { return }
            preparingShare = false
            if reviewError == nil, review?.hasShareableMeetingNotes == true {
                showingShareSheet = true
            } else {
                shareError = reviewError ?? "AI didn't produce shareable meeting notes. Click Share notes to try again."
            }
        }
        .task(id: askTick) {
            guard askTick > 0, let question = pendingAsk else { return }
            await runSessionAsk(question)
        }
    }

    private var meetingIsBusy: Bool {
        reviewInProgress || regenerating || preparingShare || askBusy != nil || pendingAsk != nil
    }

    private func deleteMeeting() {
        guard !meetingIsBusy else { return }
        do {
            try TranscriptStore.deleteMeeting(at: url)
            onClose()
        } catch {
            deleteError = "Some files couldn't be removed. Please try again. \(error.localizedDescription)"
        }
    }

    // MARK: header — meta, title, actions, tabs

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(metaLine)
                        .font(Dorado.roboto(13))
                        .foregroundStyle(Dorado.grey500)
                    if renaming {
                        TextField("Session title", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Dorado.midnight)
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renaming = false }
                    } else {
                        Text(title)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Dorado.midnight)
                            .lineLimit(2)
                            .onTapGesture {
                                renameText = TranscriptSearch.headerTitle(at: url) ?? ""
                                renaming = true
                                renameFocused = true
                            }
                            .help("Click to rename")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button {
                        copyTranscript()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                            Text("Copy")
                        }
                    }
                    .buttonStyle(DoradoOutlineButtonStyle())
                    .help("Copy the plain-text transcript")

                    Menu {
                        Button("Markdown (.md)") { export(as: .markdown) }
                        Button("Plain text (.txt)") { export(as: .plainText) }
                        Button("Summary (.txt)") { export(as: .summary) }
                            .disabled(review == nil)
                        Divider()
                        Button("Open file in editor") { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                            Text("Export")
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(DoradoOutlineButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(DoradoOutlineButtonStyle())
                    .disabled(meetingIsBusy)
                    .accessibilityLabel("Delete meeting")
                    .help(meetingIsBusy ? "Wait for the current meeting operation to finish" : "Delete meeting")

                    Button { onClose() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "house")
                                .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                            Text("Meetings")
                        }
                    }
                    .buttonStyle(DoradoOutlineButtonStyle())
                    .help("Back to your meetings")
                }
            }

            tabBar
        }
        .padding(.init(top: 28, leading: 28, bottom: 0, trailing: 28))
    }

    @ViewBuilder
    private var shareControl: some View {
        if let record = sharedLink {
            Menu {
                if record.pending != true, let url = record.url {
                    ShareLink(
                        item: url,
                        subject: Text(title.isEmpty ? "Meeting notes" : title),
                        message: Text("Here are the meeting notes and next steps.")
                    ) {
                        Label("Send notes…", systemImage: "paperplane.fill")
                    }
                }
                Button("Copy private link") { copyPrivateLink(record) }
                    .disabled(record.pending == true)
                Button("Open private link") {
                    if let url = record.url { NSWorkspace.shared.open(url) }
                }
                .disabled(record.pending == true)
                Divider()
                Button("Stop sharing…", role: .destructive) {
                    confirmingStopShare = true
                }
            } label: {
                HStack(spacing: 7) {
                    if revokingShare {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 12)).foregroundStyle(Dorado.dollar)
                    }
                    Text(record.pending == true ? "Sharing pending" : "Shared")
                }
            }
            .menuStyle(.button)
            .buttonStyle(DoradoOutlineButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(revokingShare)
            .help("Copy, open, or stop sharing the encrypted notes snapshot")
        } else {
            Button {
                prepareShare()
            } label: {
                HStack(spacing: 7) {
                    if preparingShare {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                    }
                    Text(preparingShare ? "Preparing notes…" : "Share notes")
                }
            }
            .buttonStyle(DoradoOutlineButtonStyle())
            .disabled(preparingShare)
            .help(review?.hasShareableMeetingNotes != true
                  ? "Generate notes with your selected AI provider, then create and copy a private link"
                  : "Create and copy an encrypted 30-day private link")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(Dorado.barlowBold(15))
                        .foregroundStyle(tab == t ? Dorado.midnight : Dorado.grey500)
                        .padding(.bottom, 10)
                        .overlay(alignment: .bottom) {
                            (tab == t ? Dorado.midnight : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            shareControl.padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) { Dorado.divider.frame(height: 1) }
    }

    // MARK: tab bodies

    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .chat: chatTab
        case .transcript: transcriptTab
        case .summary: summaryTab
        case .coaching: coachingTab
        }
    }

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .top, spacing: 16) {
                            Text(line.stamp)
                                .font(Dorado.mono(12))
                                .foregroundStyle(Dorado.grey400)
                                .frame(width: 52, alignment: .leading)
                                .padding(.top, 3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.speaker)
                                    .font(Dorado.barlowBold(14))
                                    .foregroundStyle(line.speaker == "You" ? Dorado.bolt : Dorado.midnight)
                                highlightedText(line.text)
                                    .font(Dorado.roboto(15))
                                    .foregroundStyle(Dorado.grey800)
                                    .lineSpacing(6)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: 640, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .background(citedLine == i ? Dorado.doradoTint : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .id(i)
                    }
                    if lines.isEmpty {
                        Text("No transcript lines in this session.")
                            .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey400)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.init(top: 20, leading: 28, bottom: 0, trailing: 28))
            }
            .mask(
                // Bottom scroll fade over the last ~40px (spec).
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                }
            )
            .onAppear {
                if let citedLine { proxy.scrollTo(citedLine, anchor: .center) }
                else { scrollToFirstHit(proxy) }
            }
            .onChange(of: citedLine) { _, line in
                if let line { proxy.scrollTo(line, anchor: .center) }
            }
            .onChange(of: highlightQuery) { _, _ in scrollToFirstHit(proxy) }
        }
    }

    private var summaryTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if review?.hasShareableMeetingNotes != true {
                    Text("Click Share notes to generate meeting notes and create your private link. Your transcript and coaching stay private.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let review {
                    MeetingReviewView(review: review) { id in
                        toggleActionItem(id)
                    }
                } else if !regenerating {
                    Text("No summary yet.")
                        .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey400)
                }

                if let reviewError {
                    Text(reviewError).font(.caption).foregroundStyle(.red)
                }
                if settings != nil, !lines.isEmpty {
                    HStack(spacing: 8) {
                        if regenerating || reviewInProgress {
                            ProgressView().controlSize(.small)
                            Text("Writing meeting notes with AI…")
                                .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey600)
                        } else {
                            Button {
                                regenerating = true
                                regenTick += 1
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12)).foregroundStyle(Dorado.grey500)
                                    Text(review == nil ? "Generate AI review" : "Regenerate with AI")
                                }
                            }
                            .buttonStyle(DoradoOutlineButtonStyle())
                            .help("Uses your selected AI provider. Cloud AI sends meeting text to that provider.")
                        }
                    }
                }
            }
            .padding(.init(top: 20, leading: 44, bottom: 20, trailing: 44))
        }
    }

    // MARK: in-session ask

    private let starterQuestions = [
        "What did we decide, and why?",
        "What should I follow up on?",
        "What risks or open questions did we leave unresolved?"
    ]

    private var chatTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if askThread.isEmpty && pendingAsk == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 28)).foregroundStyle(Dorado.dollar)
                                Text("Put this meeting to work")
                                    .font(.system(size: 24, weight: .semibold))
                                Text("Find the decisions, connect the dots, or work out your next move.")
                                    .font(.system(size: 14)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(starterQuestions, id: \.self) { question in
                                        Button {
                                            askInput = question
                                            submitAsk()
                                        } label: {
                                            HStack {
                                                Text(question).multilineTextAlignment(.leading)
                                                Spacer()
                                                Image(systemName: "arrow.up.right")
                                            }
                                            .padding(12).frame(maxWidth: .infinity)
                                            .cardStyle()
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(askBusy != nil || lines.isEmpty || chatLoadFailed)
                                    }
                                }
                                .padding(.top, 12)
                            }
                            .padding(.top, 28)
                        }
                        ForEach(Array(askThread.enumerated()), id: \.offset) { _, turn in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Spacer(minLength: 32)
                                    Text(turn.q)
                                        .padding(12)
                                        .background(Dorado.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
                                }
                                Label("MeetMouse", systemImage: "sparkles")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Text(linkedAnswer(turn.a))
                                    .environment(\.openURL, OpenURLAction { link in
                                        guard link.scheme == "meetmouse-citation",
                                              let index = Int(link.lastPathComponent),
                                              lines.indices.contains(index) else { return .discarded }
                                        citedLine = index
                                        tab = .transcript
                                        return .handled
                                    })
                                    .font(.system(size: 15)).lineSpacing(5)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    CopyButton(help: "Copy answer") { turn.a }
                                    Button("View transcript") { tab = .transcript }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let question = pendingAsk {
                            Text(question).font(.system(size: 15, weight: .medium))
                        }
                        if let busy = askBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(busy).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let askError {
                            Text(askError).font(.callout).foregroundStyle(.secondary)
                            if chatSaveFailed {
                                Button("Retry saving chat") {
                                    do {
                                        try MeetingChatStore.save(askThread, for: url)
                                        self.askError = nil
                                        chatSaveFailed = false
                                    } catch { self.askError = "Couldn't save chat: \(error.localizedDescription)" }
                                }
                                .disabled(askBusy != nil)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(28)
                }
                .onAppear { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: askThread.count) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
                .onChange(of: askBusy) { _, _ in proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Ask this meeting…", text: $askInput, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .lineLimit(1...5).focused($askFocused)
                        .onSubmit(submitAsk)
                        .disabled(askBusy != nil || lines.isEmpty || chatLoadFailed)
                    if askBusy != nil {
                        Button("Stop") {
                            askTick += 1
                            askInput = pendingAsk ?? ""
                            pendingAsk = nil
                            askBusy = nil
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: submitAsk) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                        }
                        .buttonStyle(.plain).foregroundStyle(Dorado.dollar)
                        .disabled(askInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lines.isEmpty || chatLoadFailed)
                        .accessibilityLabel("Send question")
                    }
                }
                .padding(16).cardStyle(cornerRadius: 14)
                HStack {
                    Label(lines.isEmpty ? "This meeting has no transcript yet" : "Only this meeting · AI runs on your Mac", systemImage: "lock")
                    Spacer()
                    if !askThread.isEmpty || chatLoadFailed {
                        Button("Clear chat") { confirmClearChat = true }
                            .buttonStyle(.plain).disabled(askBusy != nil)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.bottom, 22).padding(.top, 12)
        }
    }

    private func clearChat() {
        do {
            try MeetingChatStore.remove(for: url)
            askThread = []; askError = nil; chatLoadFailed = false; chatSaveFailed = false
        } catch { askError = "Couldn't clear the saved chat: \(error.localizedDescription)" }
    }

    private func linkedAnswer(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for reference in MeetingCitations.references(in: text, stamps: lines.map(\.stamp)) {
            guard let range = Range(reference.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].link = URL(string: "meetmouse-citation://transcript/\(reference.line)")
            result[start..<end].foregroundColor = Dorado.bolt
        }
        return result
    }

    private func submitAsk() {
        let q = String(askInput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        guard !q.isEmpty, askBusy == nil, !lines.isEmpty, !chatLoadFailed else { return }
        askInput = ""
        pendingAsk = q
        askError = nil
        askBusy = "Reading this meeting…"
        askTick += 1
    }

    private func runSessionAsk(_ question: String) async {
        defer {
            if !Task.isCancelled { askBusy = nil; pendingAsk = nil }
        }
        guard let settings, let ollamaManager else {
            askError = "Configure AI in Settings → AI, or install a local model."
            askInput = question
            return
        }

        // Cloud providers need no engine, model inventory or memory check;
        // prepareAI short-circuits for them and does the Ollama dance otherwise.
        guard await settings.prepareAI(ollamaManager: ollamaManager) else {
            guard !Task.isCancelled else { return }
            askError = "AI is unavailable — check Settings → AI or install a local model."
            askInput = question
            return
        }
        guard !Task.isCancelled else { return }

        load()
        let transcriptLines = lines.map { "[\($0.stamp)] \($0.speaker): \($0.text)" }
        let excerpts = MeetingAsk.sessionExcerpts(question: question,
                                                  transcriptLines: transcriptLines,
                                                  review: review?.recapMarkdown ?? "",
                                                  priorQuestions: askThread.suffix(2).map(\.q))
        let (system, user) = MeetingAsk.sessionPrompt(question: question, excerpts: excerpts,
                                                      history: askThread.suffix(3).map { (q: $0.q, a: $0.a) })
        // Same fast-path sizing as the search-pane ask (4096 matches the
        // in-call phase; 384 covers a 150-word answer).
        let client = AIClient(model: settings.effectiveModel,
                                  numCtx: 4096, numPredict: 384)
        if !settings.usesCloudAI,
           await !OllamaClient(model: settings.effectiveModel).runningModels().contains(settings.effectiveModel) {
            guard !Task.isCancelled else { return }
            askBusy = "Warming up the local model…"
        }
        guard !Task.isCancelled else { return }
        do {
            let text = try await client.complete(system: system, user: user)
            guard !Task.isCancelled else { return }
            let cleaned = text.components(separatedBy: .newlines)
                .map(MeetingReview.clean)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                askError = "The model returned nothing — try asking again."
                askInput = question
                return
            }
            askThread.append(MeetingChatTurn(q: question, a: cleaned))
            do {
                try MeetingChatStore.save(askThread, for: url)
                chatSaveFailed = false
            } catch {
                chatSaveFailed = true
                askError = "Couldn't save this chat. Keep this meeting open and retry saving."
            }
        } catch {
            guard !Task.isCancelled else { return }
            askError = "The AI model couldn't answer (\(error.localizedDescription)). Try again."
            askInput = question
        }
    }

    /// Re-run the LLM review over this saved session's transcript and
    /// persist it into the file's "## Review" section.
    @State private var reviewError: String?

    /// The explicit Share notes action prepares missing notes, then opens link creation.
    private func prepareShare() {
        load()
        if review?.hasShareableMeetingNotes == true {
            preparingShare = false
            showingShareSheet = true
            return
        }
        preparingShare = true
        if regenerating || reviewInProgress { return }
        guard settings != nil, ollamaManager != nil, !lines.isEmpty else {
            preparingShare = false
            shareError = lines.isEmpty
                ? "This meeting has no transcript to generate notes from."
                : "AI is unavailable. Check Settings → AI, then click Share notes again."
            return
        }
        regenerating = true
        regenTick += 1
    }

    private func regenerateReview() async {
        defer { regenerating = false }
        guard let settings, let ollamaManager, !lines.isEmpty else {
            reviewError = "AI is unavailable or this meeting has no transcript."
            return
        }
        regenerating = true
        guard await settings.prepareAI(ollamaManager: ollamaManager) else {
            reviewError = "AI is unavailable — check Settings → AI or install a local model."
            return
        }
        guard !Task.isCancelled else { return }
        reviewError = nil

        let transcript = lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let (system, user) = PromptBuilder.buildPostCallReviewPrompt(
            nudges: [], transcript: transcript,
            context: PreCallContext(), durationMinutes: max(1, durationMinutes),
            languageName: languageCode.flatMap {
                MeetingLanguageSelection.resolvedPersistedCode($0)?.englishName
            })
        let text: String
        do {
            text = try await AIClient(model: settings.effectiveModel, numCtx: 12_288, numPredict: 1500)
                .complete(system: system, user: user)
        } catch {
            reviewError = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }
        let parsed = MeetingReview.parse(llmText: text, talkShare: talkShareValue)
        review = parsed
        persistReview(parsed)
        if let title = parsed.title {
            TranscriptSearch.adoptGeneratedTitle(title, for: url)
        }
    }

    private func persistReview(_ r: MeetingReview) {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let range = content.range(of: "\n## Review") {
            content = String(content[..<range.lowerBound])
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n## Review\n\n\(r.recapMarkdown)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        rawContent = content
    }

    private var coachingTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(nudgeLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Circle()
                            .fill(Dorado.dorado300)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        Text(line)
                            .font(Dorado.roboto(15))
                            .foregroundStyle(Dorado.grey800)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                }
                if nudgeLines.isEmpty {
                    Text("No coaching nudges fired in this session.")
                        .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey400)
                }
            }
            .padding(.init(top: 20, leading: 44, bottom: 20, trailing: 44))
        }
    }

    // MARK: helpers

    private func highlightedText(_ text: String) -> Text {
        guard !highlightQuery.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        // Per-word, matching the search's all-words semantics.
        for token in TranscriptSearch.queryTokens(highlightQuery) {
            var searchStart = attributed.startIndex
            while let range = attributed[searchStart...].range(
                of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].backgroundColor = Dorado.dorado100
                attributed[range].foregroundColor = Dorado.midnight
                searchStart = range.upperBound
            }
        }
        return Text(attributed)
    }

    private func scrollToFirstHit(_ proxy: ScrollViewProxy) {
        guard !highlightQuery.isEmpty else { return }
        let tokens = TranscriptSearch.queryTokens(highlightQuery)
        guard let i = lines.firstIndex(where: {
            TranscriptSearch.matchesAllTokens($0.text, tokens: tokens)
        }) else { return }
        withAnimation { proxy.scrollTo(i, anchor: .center) }
    }

    private func commitRename() {
        renaming = false
        TranscriptSearch.setTitle(renameText, for: url)
        title = TranscriptSearch.displayTitle(for: url)
    }

    private var plainTranscript: String {
        lines.map { "[\($0.stamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainTranscript, forType: .string)
    }

    private enum ExportKind { case markdown, plainText, summary }

    private func export(as kind: ExportKind) {
        let panel = NSSavePanel()
        let base = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        let content: String
        switch kind {
        case .markdown:
            panel.nameFieldStringValue = "\(base).md"
            content = rawContent
        case .plainText:
            panel.nameFieldStringValue = "\(base).txt"
            content = plainTranscript
        case .summary:
            panel.nameFieldStringValue = "\(base) — summary.txt"
            content = review?.recapMarkdown ?? ""
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? content.write(to: dest, atomically: true, encoding: .utf8)
    }

    private func copyPrivateLink(_ record: SharedLinkRecord) {
        guard let url = record.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func stopSharing(_ record: SharedLinkRecord) async {
        revokingShare = true
        defer { revokingShare = false }
        do {
            try await WebShareService().revoke(record)
            try await SharedLinksStore.shared.remove(record)
            sharedLink = nil
        } catch {
            shareError = error.localizedDescription
        }
    }

    // MARK: load

    private func load() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            title = "Couldn't read session"
            metaLine = ""; review = nil; lines = []; nudgeLines = []; rawContent = ""
            return
        }
        rawContent = content
        title = TranscriptSearch.headerTitle(in: content) ?? TranscriptSearch.title(for: url)

        var duration = ""
        var talkShare = ""
        languageCode = nil
        var participants = 0
        var newLines: [(String, String, String)] = []
        var newNudges: [String] = []
        var reviewLines: [String] = []
        var section = ""
        for rawLine in content.components(separatedBy: "\n") {
            if rawLine.hasPrefix("## ") {
                section = rawLine
                continue
            }
            if section.hasPrefix("## Review") {
                reviewLines.append(rawLine)
                continue
            }
            if section.hasPrefix("## Nudges") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    newNudges.append(String(trimmed.dropFirst(2)))
                }
                continue
            }
            if let parsed = TranscriptSearch.parseTranscriptLine(rawLine) {
                newLines.append(parsed)
                continue
            }
            if rawLine.hasPrefix("**Duration:**") {
                duration = rawLine.dropFirst("**Duration:**".count).trimmingCharacters(in: .whitespaces)
            }
            if rawLine.hasPrefix("**Talk ratio:**") {
                talkShare = rawLine.dropFirst("**Talk ratio:**".count).trimmingCharacters(in: .whitespaces)
            }
            if rawLine.hasPrefix("**Language:**") {
                languageCode = rawLine.dropFirst("**Language:**".count)
                    .trimmingCharacters(in: .whitespaces)
            }
            if rawLine.hasPrefix("**Participants:**") {
                participants = rawLine.split(separator: ",").count
            }
        }
        lines = newLines
        nudgeLines = newNudges

        // "Today, 9:00 AM · 32 min · 4 people · 41% your talk share"
        var meta: [String] = []
        if let date = Dorado.sessionDate(url) {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            let day = Calendar.current.isDateInToday(date) ? "Today"
                : Calendar.current.isDateInYesterday(date) ? "Yesterday"
                : { let d = DateFormatter(); d.dateFormat = "MMM d"; return d.string(from: date) }()
            meta.append("\(day), \(f.string(from: date))")
        }
        if !duration.isEmpty {
            let mins = Int(SessionSummary.minutes(from: duration).rounded())
            durationMinutes = mins
            meta.append(mins > 0 ? "\(mins) min" : duration)
        }
        let speakerCount = Set(newLines.map(\.1)).count
        let people = max(participants, speakerCount)
        if people > 1 { meta.append("\(people) people") }
        if !talkShare.isEmpty {
            meta.append(talkShare.replacingOccurrences(of: "% you", with: "% your talk share"))
        }
        metaLine = meta.joined(separator: " · ")

        var share: Double?
        let digits = talkShare.prefix(while: \.isNumber)
        if let pct = Int(digits) { share = Double(pct) / 100 }
        talkShareValue = share
        let reviewText = reviewLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        review = reviewText.isEmpty ? nil : MeetingReview.parse(llmText: reviewText, talkShare: share)

    }

    /// Checkbox toggles persist straight into the file's "## Review"
    /// section — same behavior as the post-call card.
    private func toggleActionItem(_ id: UUID) {
        guard var updated = review,
              let i = updated.actionItems.firstIndex(where: { $0.id == id }) else { return }
        updated.actionItems[i].isDone.toggle()
        review = updated
        guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
        if let range = content.range(of: "\n## Review") {
            content = String(content[..<range.lowerBound])
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n## Review\n\n\(updated.recapMarkdown)\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
        rawContent = content
    }
}
