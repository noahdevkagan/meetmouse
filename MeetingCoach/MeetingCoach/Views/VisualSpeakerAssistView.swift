import SwiftUI

/// Manual window consent can also authorize automatic snapshots in future meetings.
struct VisualSpeakerAssistView: View {
    var liveSession: LiveSessionViewModel
    @State private var showConsent = false
    @State private var rememberAutomatic = false
    @State private var selected: SpeakerWindowChoice?
    @State private var loading = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.rectangle")
                .foregroundStyle(.secondary)
            if liveSession.visualSpeakerCapture.status.isEmpty {
                Button("Help name speakers with screenshots…") { showConsent = true }
                    .buttonStyle(.plain)
            } else {
                Text(liveSession.speakerNameSuggestions.contains(where: { $0.kind == .visualName })
                     ? "Speaker name matches ready. Confirm the suggestions below."
                     : liveSession.visualSpeakerCapture.status)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if liveSession.visualSpeakerCapture.isRunning || liveSession.visualSpeakerCapture.isDiscovering {
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
                Text("Choose your call. MeetMouse reads up to six snapshots on this Mac and suggests names for you to confirm.")
                SpeakerWindowPicker(selected: $selected, loading: $loading)
                DisclosureGroup("How speaker snapshots work") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Images are discarded after reading. No screenshots or window text are saved or sent to AI. Confirmed names become part of your transcript and saved voice profiles.")
                        Text("Keep participant names visible. MeetMouse reads Zoom’s green/yellow speaker outline or Google Meet’s blue outline. One-on-one Zoom calls can also use your name from Settings to find the other tile.")
                        Text("Keep the call window visible. Ambiguous layouts and chat messages won’t produce matches. Six snapshots run over about 90 seconds.")
                    }
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
                Toggle("Start automatically in future meetings", isOn: $rememberAutomatic)
                Text("When enabled, MeetMouse detects one meeting window and takes up to six snapshots each meeting. Change this in Settings → General → Speaker names.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Nothing is captured until you click Allow. macOS may show its screen-capture indicator. You can stop at any time.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showConsent = false }
                    Button(rememberAutomatic ? "Allow and remember" : "Allow for this meeting") {
                        if let selected {
                            UserDefaults.standard.set(rememberAutomatic,
                                                      forKey: VisualSpeakerCapture.automaticDefaultsKey)
                            liveSession.startVisualSpeakerAssistance(window: selected)
                        }
                        showConsent = false
                    }
                    .disabled(loading || selected == nil || !liveSession.isLive || liveSession.micOnly)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24).frame(width: 510)
            .task {
                rememberAutomatic = UserDefaults.standard.bool(forKey: VisualSpeakerCapture.automaticDefaultsKey)
            }
        }
        .onChange(of: liveSession.isLive) { _, live in
            if !live { showConsent = false }
        }
    }

}

/// Window metadata only: selecting a call never captures pixels before Allow.
struct SpeakerWindowPicker: View {
    @Binding var selected: SpeakerWindowChoice?
    @Binding var loading: Bool
    @State private var windows: [SpeakerWindowChoice] = []
    @State private var chooseManually = false
    @State private var loadError: String?
    @State private var countdown = 0
    @State private var switchTask: Task<Void, Never>?

    private var calls: [SpeakerWindowChoice] { VisualSpeakerCapture.meetingWindows(in: windows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if countdown > 0 {
                Label("Switch to your call now · \(countdown)", systemImage: "macwindow")
                    .font(.headline)
                    .accessibilityLabel("Switch to your call now. \(countdown) seconds remaining.")
                Text("Click your Zoom or Meet window. MeetMouse will select it, then bring you back here.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { cancelSwitch() }
            } else if loading {
                ProgressView("Finding your meeting window…")
            } else {
                Text(calls.count == 1 ? "Detected call" : "Choose your call").font(.headline)
                if !calls.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(calls) { window in
                                Button {
                                    selected = window
                                    chooseManually = false
                                    loadError = nil
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selected == window ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(selected == window ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(window.platformName).fontWeight(.medium)
                                            Text(window.title).font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(window.platformName), \(window.title)")
                                .accessibilityAddTraits(selected == window ? [.isSelected] : [])
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(CGFloat(calls.count) * 62, 186))
                } else {
                    Text("Bring your call to the front so MeetMouse can find it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Find the call I switch to…", systemImage: "macwindow") { startSwitch() }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Choose from all windows", isExpanded: $chooseManually) {
                    Picker("Window", selection: $selected) {
                        Text("Choose a window").tag(nil as SpeakerWindowChoice?)
                        ForEach(windows) { window in
                            Text("\(window.app) — \(window.title)").tag(Optional(window))
                        }
                    }.padding(.top, 8)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadWindows() } }
                    .font(.caption)
            }
        }
        .task { await loadWindows() }
        .onDisappear { cancelSwitch() }
    }

    private func cancelSwitch() {
        switchTask?.cancel()
        switchTask = nil
        countdown = 0
        loading = false
    }

    private func startSwitch() {
        cancelSwitch()
        selected = nil
        loadError = nil
        countdown = 5
        loading = true
        switchTask = Task { @MainActor in
            do {
                for remaining in (1...5).reversed() {
                    countdown = remaining
                    try await Task.sleep(for: .seconds(1))
                }
                let freshWindows = try await VisualSpeakerCapture.windows()
                try Task.checkCancellation()
                windows = freshWindows
                selected = VisualSpeakerCapture.foregroundMeetingWindow(in: freshWindows)
                chooseManually = false
                if selected == nil {
                    loadError = "No call found in front. Try again with the call visible, or choose it above."
                }
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError {
                return
            } catch {
                loadError = "Couldn’t find the call. Check Screen Recording permission, then try again."
                NSApp.activate(ignoringOtherApps: true)
            }
            countdown = 0
            loading = false
            switchTask = nil
        }
    }

    private func loadWindows() async {
        loading = true
        loadError = nil
        do {
            let freshWindows = try await VisualSpeakerCapture.windows()
            try Task.checkCancellation()
            windows = freshWindows
            // Keep an explicit selection only while that exact window remains.
            if selected == nil || !windows.contains(selected!) {
                selected = VisualSpeakerCapture.suggestedWindow(in: windows)
            }
            if windows.isEmpty { loadError = "Open your meeting window, then refresh." }
        } catch is CancellationError {
            return
        } catch {
            windows = []
            selected = nil
            loadError = "Allow Screen Recording for MeetMouse in System Settings, then refresh."
        }
        loading = false
    }
}
