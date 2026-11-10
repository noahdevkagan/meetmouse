import SwiftUI

/// Debug-only UI preview for the AI setup screens. Read from the launch
/// environment, never persisted, and compiled out of release builds: in release
/// every member returns the normal value.
///   MC_PREVIEW_AI_SETUP=1                  setup UI behaves as if AI isn't set up
///   MC_PREVIEW_CLAUDE_CLI=missing|outdated|ok   what the setup UI shows for Claude Code
/// Preview changes only what the setup UI displays; real actions are inert.
enum DebugPreview {
    static let note = "Preview mode — nothing was changed."
    #if DEBUG
    private static let environment = ProcessInfo.processInfo.environment
    static let active = environment["MC_PREVIEW_AI_SETUP"] == "1"
    static var cliStatus: ClaudeAccount.CLIStatus? {
        guard active else { return nil }
        switch environment["MC_PREVIEW_CLAUDE_CLI"] {
        case "missing": return .missing
        case "outdated": return .outdated
        case "broken": return .broken
        case "ok": return .ready
        default: return nil
        }
    }
    #else
    static let active = false
    static var cliStatus: ClaudeAccount.CLIStatus? { nil }
    #endif
}

/// Drives the two-choice AI setup: sign in with a Claude account (installing
/// Claude Code first if needed) or download a local model. Shared by the
/// onboarding checklist, the home "Set up AI notes" card and the sheet opened
/// from "basic recap" / AI-unavailable messages. Provider, consent and model
/// download all go through the same `SettingsViewModel` / `ClaudeAccount`
/// calls Settings → AI uses.
@MainActor @Observable
final class AISetupModel {
    enum Step: Equatable {
        case choose
        case needsInstall(InstallKind, note: String? = nil)
        case installing
        case installFailed(String)
        case signingIn
        case consent
        case enabling
    }

    enum InstallKind: Equatable { case missing, outdated, broken }

    private(set) var step: Step = .choose
    /// What the install step describes; carried through cancel and retry.
    private var installKind: InstallKind = .missing
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var runID = 0
    /// Shown instead of acting when DebugPreview is on.
    private(set) var previewNote: String?

    var isWorking: Bool { [.installing, .signingIn, .enabling].contains(step) }

    func chooseClaude() {
        error = nil
        previewNote = nil
        run(.signingIn) { [self] id in
            do {
                let status: ClaudeAccount.CLIStatus
                if let preview = DebugPreview.cliStatus { status = preview }
                else { status = try await ClaudeAccount.cliStatus() }
                if DebugPreview.active, status == .ready {
                    // Preview: show the consent step without signing in.
                    step = .consent
                    return
                }
                switch status {
                case .missing: installKind = .missing; step = .needsInstall(.missing)
                case .outdated: installKind = .outdated; step = .needsInstall(.outdated)
                case .broken: installKind = .broken; step = .needsInstall(.broken)
                case .slow:
                    if runID == id { error = ClaudeAccount.slowMessage; step = .choose }
                case .ready: await signIn(id)
                }
            } catch is CancellationError {
                if runID == id { step = .choose }
            } catch {
                if runID == id { self.error = error.localizedDescription; step = .choose }
            }
        }
    }

    /// Only ever called from the Install button.
    func installClaudeCode() {
        error = nil
        if DebugPreview.active { previewNote = DebugPreview.note; return }
        run(.installing) { [self] id in
            do {
                try await ClaudeAccount.install()
                try Task.checkCancellation()
                await signIn(id)
            } catch is CancellationError {
                if runID == id { step = .needsInstall(installKind) }
            } catch is ClaudeAccount.InstalledThenCancelled {
                // The installer finished; only the final check was cancelled.
                if runID == id {
                    step = .choose
                    error = "Claude Code is installed. Click Use my Claude account to continue."
                }
            } catch is ClaudeAccount.InstallInterrupted {
                if runID == id {
                    step = .needsInstall(installKind, note: "The install was stopped part-way, so some files may already be in your home folder. Installing again is safe.")
                }
            } catch {
                if runID == id { step = .installFailed(error.localizedDescription) }
            }
        }
    }

    /// Skips the browser when Claude Code is already signed in. Sending meeting
    /// text takes the separate, explicit consent step.
    private func signIn(_ id: Int) async {
        guard runID == id else { return }
        step = .signingIn
        do {
            do { try await ClaudeAccount.checkConnection() }
            catch is CancellationError { throw CancellationError() }
            catch { try await ClaudeAccount.login() }
            try Task.checkCancellation()
            guard runID == id else { return }
            step = .consent
        } catch is CancellationError {
            if runID == id { step = .choose }
        } catch {
            guard runID == id else { return }
            self.error = error.localizedDescription
            step = .choose
        }
    }

    /// A `ConsentClick` can only be made by the "Turn on AI notes" button action (its
    /// init is fileprivate); the disclosure sits directly above that button.
    func enableClaude(settings: SettingsViewModel, consent: ConsentClick, onReady: @escaping () -> Void) {
        guard step == .consent, let model = AIProvider.claudeAccount.models.first else { return }
        if DebugPreview.active { previewNote = DebugPreview.note; return }
        step = .enabling
        let configuration = AIConfiguration(provider: .claudeAccount, model: model)
        task = Task { [self] in
            do {
                try await ClaudeAccount.checkConnection()
                try Task.checkCancellation()
                try settings.enableCloudAI(configuration, key: "")
                step = .choose
                onReady()
            } catch is CancellationError {
                step = .consent
            } catch {
                self.error = error.localizedDescription
                step = .consent
            }
        }
    }

    func downloadLocal(settings: SettingsViewModel) {
        error = nil
        if DebugPreview.active { previewNote = DebugPreview.note; return }
        settings.downloadModel(recommendedCatalogModel, switchToLocalOnSuccess: true)
    }

    func cancel() {
        task?.cancel()
        task = nil
        // While installing, the task's own handler picks the screen once the
        // installer processes are really stopped (it may turn out the install finished).
        if isWorking, step != .installing { step = .choose }
    }

    func back() { cancel(); runID += 1; error = nil; previewNote = nil; step = .choose }

    private func run(_ initial: Step, _ body: @escaping @MainActor (Int) async -> Void) {
        task?.cancel()
        runID += 1
        let id = runID
        step = initial
        task = Task { await body(id) }
    }
}

struct AISetupView: View {
    var settings: SettingsViewModel
    /// Called once when AI becomes ready through this view.
    var onReady: (() -> Void)?
    /// A local-model download is already queued behind another step (onboarding):
    /// the local option waits instead of starting a second download.
    var localQueued = false
    @State private var model = AISetupModel()
    @State private var announced = false

    private var downloading: Bool { settings.downloadingModel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if downloading {
                downloadProgress
            } else {
                switch model.step {
                case .choose: choices
                case .needsInstall(let kind, let note): installPrompt(kind, note: note)
                case .installing: working("Downloading and installing Claude Code from Anthropic. This can take a minute.")
                case .installFailed(let message): installFailed(message)
                case .signingIn: working("Finish signing in to Claude in your browser…")
                case .consent, .enabling: consent
                }
            }
            if let note = model.previewNote {
                Text(note).font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            if let message = model.error {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: settings.aiReady) { _, ready in
            if ready { announce() }
        }
        .onChange(of: settings.usesCloudAI) { _, cloud in
            // Switched from a Claude account to a freshly downloaded local model.
            if !cloud, settings.aiReady { announce() }
        }
        .onDisappear { model.cancel() }
    }

    private func announce() {
        guard !announced else { return }
        announced = true
        onReady?()
    }

    // MARK: Choices

    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { claudeButton; localButton }
                VStack(alignment: .leading, spacing: 8) { claudeButton; localButton }
            }
            if let failure = settings.downloadError {
                HStack(spacing: 8) {
                    Text(failure.replacingOccurrences(of: "error: ", with: "Download failed: "))
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { model.downloadLocal(settings: settings) }.font(.caption)
                }
            }
        }
    }

    private var claudeButton: some View {
        Button("Use my Claude account") { model.chooseClaude() }
            .buttonStyle(AISetupPrimaryStyle())
            .accessibilityLabel("Use my Claude account for AI notes")
    }

    @ViewBuilder private var localButton: some View {
        let size = recommendedCatalogModel.diskSize.replacingOccurrences(of: "~", with: "")
        if localQueued {
            Button("Download a model · starts soon") {}
                .controlSize(.small).disabled(true)
                .accessibilityLabel("Model download is queued and starts after the speech model")
        } else {
            Button("Download a model · \(size)") { model.downloadLocal(settings: settings) }
                .controlSize(.small)
                .accessibilityLabel("Download a model that runs on this Mac, \(size)")
        }
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Downloading your local model…").font(Dorado.barlowBold(14)).foregroundStyle(Dorado.midnight)
            ProgressView(value: settings.downloadProgress).controlSize(.small)
            HStack {
                Text(settings.downloadStatus).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { settings.cancelDownload() }.font(.caption)
            }
            Text("You can close this. The download keeps going and your notes switch on when it's done.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Claude steps

    private func working(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { model.cancel() }.font(.caption)
        }
    }

    private func installPrompt(_ kind: AISetupModel.InstallKind, note: String?) -> some View {
        let title: String, line: String, button: String
        switch kind {
        case .missing:
            title = "Claude sign-in needs Claude Code"
            line = "Anthropic's free app. Installs to your home folder, no password needed."
            button = "Install Claude Code"
        case .outdated:
            title = "Claude Code needs an update"
            line = "The copy on this Mac is too old. The update goes in your home folder, no password needed."
            button = "Update Claude Code"
        case .broken:
            title = "Claude Code won't start"
            line = "It's on this Mac but doesn't run. Reinstalling goes in your home folder, no password needed."
            button = "Reinstall Claude Code"
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Dorado.barlowBold(14)).foregroundStyle(Dorado.midnight)
            Text(line)
                .font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(button) { model.installClaudeCode() }
                    .buttonStyle(AISetupPrimaryStyle())
                Button("Back") { model.back() }.controlSize(.small)
            }
        }
    }

    private func installFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Try again") { model.installClaudeCode() }
                    .buttonStyle(AISetupPrimaryStyle())
                Link("Install it yourself ↗", destination: ClaudeAccount.installDocsURL).font(.caption)
                Button("Back") { model.back() }.controlSize(.small)
            }
        }
    }

    @State private var showingDetails = false

    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Signed in to Claude", systemImage: "checkmark.circle.fill")
                .font(Dorado.barlowBold(14)).foregroundStyle(Dorado.midnight)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your meeting transcripts, notes and the questions you ask are sent to Anthropic.")
                Text("Audio stays on this Mac. Uses your Claude plan's limits.")
                if settings.semanticCoachEnabled {
                    Text("Live coaching also sends text during the call.")
                }
            }
            .font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
            .fixedSize(horizontal: false, vertical: true)
            Button("What's sent?") { showingDetails.toggle() }
                .buttonStyle(.link).font(.caption)
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    Text(settings.cloudConsentText(providerTitle: "Anthropic through your Claude account"))
                        .font(Dorado.roboto(12)).padding(14).frame(width: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
            HStack(spacing: 8) {
                Button(model.step == .enabling ? "Turning on…" : "Turn on AI notes") {
                    model.enableClaude(settings: settings, consent: ConsentClick(), onReady: announce)
                }
                .buttonStyle(AISetupPrimaryStyle())
                .disabled(model.step == .enabling)
                Button("Back") { model.back() }.controlSize(.small)
                    .disabled(model.step == .enabling)
            }
        }
    }
}

/// Proof that the user pressed "Turn on AI notes". Only this file can create one.
struct ConsentClick { fileprivate init() {} }

/// The home screen card shown until an AI provider is working (only when the
/// first-run checklist is gone). One line plus the same two buttons.
struct AISetupCard: View {
    var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI notes").font(Dorado.barlowBold(17)).foregroundStyle(Dorado.midnight)
                Text("Summary and follow-ups after each call. Until then you get a basic recap.")
                    .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey600)
            }
            AISetupView(settings: settings)
        }
        .padding(16)
        .cardStyle(cornerRadius: 12)
    }
}

/// The same setup in a sheet, opened from the button next to "basic recap" and
/// AI-unavailable messages. Closes itself once AI is working.
struct AISetupSheet: View {
    var settings: SettingsViewModel
    var onReady: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up AI notes").font(Dorado.barlowXBold(20)).foregroundStyle(Dorado.midnight)
            Text("Summary and follow-ups after each call. Change it any time in Settings.")
                .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey600)
            AISetupView(settings: settings) {
                dismiss()
                onReady()
            }
            HStack { Spacer(); Button("Not now") { dismiss() } }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// "Set up AI notes" button that opens the sheet. `onReady` runs after AI works.
struct SetUpAINotesButton: View {
    var settings: SettingsViewModel?
    var onReady: () -> Void = {}
    @State private var showing = false

    var body: some View {
        if let settings {
            Button("Set up AI notes") { showing = true }
                .font(.caption)
                .sheet(isPresented: $showing) {
                    AISetupSheet(settings: settings, onReady: onReady)
                }
        }
    }
}

/// Compact primary action in the app's brand green. Drawn with fixed colors so it
/// stays clearly primary whether or not the window is focused (the system
/// prominent style greys out in inactive windows).
struct AISetupPrimaryStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Dorado.roboto(12, .semibold))
            .foregroundStyle(Dorado.midnight)
            .padding(.vertical, 5).padding(.horizontal, 12)
            .background(Capsule().fill(configuration.isPressed ? Dorado.dorado500 : Dorado.dorado300))
            .contentShape(Capsule())
            .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
            .opacity(enabled ? 1 : 0.45)
    }
}
