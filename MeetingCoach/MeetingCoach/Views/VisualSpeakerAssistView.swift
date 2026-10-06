import SwiftUI

/// Consent is per meeting and per window; opening the sheet captures no images.
struct VisualSpeakerAssistView: View {
    var liveSession: LiveSessionViewModel
    @State private var showConsent = false
    @State private var windows: [SpeakerWindowChoice] = []
    @State private var selected: SpeakerWindowChoice?
    @State private var chooseManually = false
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.rectangle")
                .foregroundStyle(.secondary)
            if liveSession.visualSpeakerCapture.status.isEmpty {
                Button("Help name speakers with screenshots…") { showConsent = true }
                    .buttonStyle(.plain)
            } else {
                Text(liveSession.visualSpeakerCapture.status)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if liveSession.visualSpeakerCapture.isRunning {
                    Button("Stop") { liveSession.stopVisualSpeakerAssistance() }
                } else if liveSession.visualSpeakerCapture.count < VisualSpeakerCapture.limit {
                    Button("Help name speakers…") { showConsent = true }
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .sheet(isPresented: $showConsent) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Help match names to voices").font(.title2.bold())
                Text("For this meeting, take up to six silent screenshots of one window over about 90 seconds. MeetMouse reads the highlighted speaker’s name on this Mac and offers matches for you to confirm.")
                Text("Images are discarded after reading. No screenshots or window text are saved or sent to AI. Confirmed names become part of your transcript and saved voice profiles.")
                    .foregroundStyle(.secondary)
                Text("Works best with Zoom’s green or yellow speaker outline and visible names. Keep the meeting window visible. Ambiguous layouts, chat messages, and unhighlighted tiles won’t produce matches.")
                    .font(.callout).foregroundStyle(.secondary)
                if loading {
                    ProgressView("Finding your meeting window…")
                } else {
                    if !chooseManually, let selected {
                        LabeledContent("Detected meeting") {
                            Text("\(selected.app) — \(selected.title)")
                                .lineLimit(2)
                                .help("\(selected.app) — \(selected.title)")
                        }
                        Button("Choose another window…") { chooseManually = true }
                    } else {
                        if selected == nil {
                            Text("Couldn’t identify one meeting window. Choose the window to use.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Meeting window", selection: $selected) {
                            Text("Choose a window").tag(nil as SpeakerWindowChoice?)
                            ForEach(windows) { window in
                                Text("\(window.app) — \(window.title)")
                                    .tag(Optional(window))
                            }
                        }
                    }
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.secondary) }
                    Button("Refresh windows") { Task { await loadWindows() } }
                }
                Text("Nothing is captured until you click Allow. macOS may show its screen-capture indicator. You can stop at any time.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showConsent = false }
                    Button("Allow for this meeting") {
                        if let selected { liveSession.startVisualSpeakerAssistance(window: selected) }
                        showConsent = false
                    }
                    .disabled(loading || selected == nil || !liveSession.isLive || liveSession.micOnly)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24).frame(width: 510)
            .task { await loadWindows() }
        }
        .onChange(of: liveSession.isLive) { _, live in
            if !live { showConsent = false }
        }
    }

    private func loadWindows() async {
        loading = true
        selected = nil
        chooseManually = false
        loadError = nil
        do {
            windows = try await VisualSpeakerCapture.windows()
            selected = VisualSpeakerCapture.suggestedWindow(in: windows)
            chooseManually = selected == nil
            if windows.isEmpty { loadError = "Open your meeting window, then refresh." }
        } catch {
            windows = []
            loadError = "Allow Screen Recording for MeetMouse in System Settings, then try again."
        }
        loading = false
    }
}
