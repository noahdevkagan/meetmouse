import SwiftUI

/// "Get great meeting notes" — connects the Claude account (or points to the
/// other providers / a local model) from where the user actually wants
/// notes: onboarding and a saved meeting whose notes came out basic.
/// Transcript-first is the default, so this is the one AI setup we push.
/// Cloud stays an explicit opt-in: signing in alone never enables it — the
/// same consent the AI settings tab asks for is required here too.
struct NotesAIConnectView: View {
    enum Style { case card, inline }

    var settings: SettingsViewModel
    var style: Style = .card
    /// Called once cloud AI is enabled (e.g. to regenerate this meeting's notes).
    var onEnabled: (() -> Void)?
    var onDismiss: (() -> Void)?

    @Environment(\.openSettings) private var openSettings
    @State private var working = false
    @State private var connected = false
    @State private var consent = false
    @State private var status: String?
    @State private var isError = false
    @State private var task: Task<Void, Never>?

    /// Notes are the one long, once-per-meeting job — Sonnet's extra quality
    /// is worth it there, and coaching (the per-minute cost) is off by default.
    private static let notesModel = "sonnet"

    var body: some View {
        Group {
            if style == .card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Get much better meeting notes", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let onDismiss {
                            Button { onDismiss() } label: {
                                Image(systemName: "xmark").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Not now")
                        }
                    }
                    Text("Connect your Claude account and MeetMouse writes clean, topic-by-topic notes and next steps after every call. Transcription and audio stay on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controls
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()
            } else {
                controls
            }
        }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settings.usesCloudAI {
                Label("\(settings.aiConfiguration.provider.title) writes your notes", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Dorado.dollar)
            } else if connected {
                Text("When enabled, meeting text and participant names go to Claude to write notes and answer chat questions. Audio and transcription stay on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Allow MeetMouse to send meeting text to Claude", isOn: $consent)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Button("Turn on Claude notes") { enable() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!consent || working)
            } else {
                HStack(spacing: 8) {
                    Button(working ? "Waiting for Claude…" : "Connect Claude account") { connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(working)
                    if working {
                        Button("Cancel") { task?.cancel() }
                            .controlSize(.small)
                    }
                }
                if ClaudeAccount.executable == nil {
                    Link("Needs Claude Code — install it first ↗",
                         destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                        .font(.caption)
                }
                HStack(spacing: 12) {
                    Button("Use an API key instead") { openSettings() }
                    localModelButton
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Dorado.bolt)
            }
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The offline path stays one click away — local-first is the promise.
    @ViewBuilder private var localModelButton: some View {
        if settings.downloadingModel != nil {
            Text("Downloading local model… \(Int(settings.downloadProgress * 100))%")
                .foregroundStyle(.secondary)
        } else if settings.availableModels.isEmpty {
            Button("Or download a local model (\(recommendedCatalogModel.diskSize))") {
                settings.downloadModel(recommendedCatalogModel)
            }
        }
    }

    private func connect() {
        working = true; isError = false
        status = "Complete sign-in in your browser if it opens…"
        task = Task {
            defer { working = false }
            do {
                // Already signed in to Claude Code? Skip the browser round-trip.
                do { try await ClaudeAccount.checkConnection() }
                catch { try await ClaudeAccount.login() }
                try Task.checkCancellation()
                connected = true
                status = nil
            } catch is CancellationError {
                status = "Sign-in cancelled."
            } catch {
                status = error.localizedDescription; isError = true
            }
        }
    }

    private func enable() {
        isError = false; status = nil
        do {
            try settings.enableCloudAI(.init(provider: .claudeAccount, model: Self.notesModel), key: "")
            onEnabled?()
        } catch {
            status = error.localizedDescription; isError = true
        }
    }
}
