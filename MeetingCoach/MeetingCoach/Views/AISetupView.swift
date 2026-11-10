import SwiftUI

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
        case needsInstall(outdated: Bool)
        case installing
        case installFailed(String)
        case signingIn
        case consent
        case enabling
    }

    private(set) var step: Step = .choose
    private(set) var error: String?
    var consent = false
    private var task: Task<Void, Never>?

    var isWorking: Bool { [.installing, .signingIn, .enabling].contains(step) }

    func chooseClaude() {
        error = nil
        run(.signingIn) { [self] in
            switch await ClaudeAccount.cliStatus() {
            case .missing: step = .needsInstall(outdated: false)
            case .outdated: step = .needsInstall(outdated: true)
            case .ready: await signIn()
            }
        }
    }

    /// Only ever called from the Install button.
    func installClaudeCode() {
        error = nil
        run(.installing) { [self] in
            do {
                try await ClaudeAccount.install()
                try Task.checkCancellation()
                await signIn()
            } catch is CancellationError {
                step = .needsInstall(outdated: false)
            } catch {
                step = .installFailed(error.localizedDescription)
            }
        }
    }

    /// Skips the browser when Claude Code is already signed in. Sending meeting
    /// text takes the separate, explicit consent step.
    private func signIn() async {
        step = .signingIn
        do {
            do { try await ClaudeAccount.checkConnection() }
            catch is CancellationError { throw CancellationError() }
            catch { try await ClaudeAccount.login() }
            try Task.checkCancellation()
            consent = false
            step = .consent
        } catch is CancellationError {
            step = .choose
        } catch {
            self.error = error.localizedDescription
            step = .choose
        }
    }

    func enableClaude(settings: SettingsViewModel, onReady: @escaping () -> Void) {
        guard consent, let model = AIProvider.claudeAccount.models.first else { return }
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
        if settings.usesCloudAI { settings.useLocalAI() }
        settings.downloadModel(recommendedCatalogModel)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if step == .installing { step = .needsInstall(outdated: false) }
        else if isWorking { step = .choose }
    }

    func back() { cancel(); error = nil; consent = false; step = .choose }

    private func run(_ initial: Step, _ body: @escaping @MainActor () async -> Void) {
        task?.cancel()
        step = initial
        task = Task { await body() }
    }
}

struct AISetupView: View {
    var settings: SettingsViewModel
    /// Called once when AI becomes ready through this view.
    var onReady: (() -> Void)?
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
                case .needsInstall(let outdated): installPrompt(outdated: outdated)
                case .installing: working("Downloading and installing Claude Code from Anthropic. This can take a minute.")
                case .installFailed(let message): installFailed(message)
                case .signingIn: working("Finish signing in to Claude in your browser…")
                case .consent, .enabling: consent
                }
            }
            if let message = model.error {
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: settings.aiReady) { _, ready in
            if ready { announce() }
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
        VStack(alignment: .leading, spacing: 10) {
            optionRow(title: "Use my Claude account",
                      detail: "Sign in with your own Claude plan. Uses your plan's limits. Meeting text is sent to Anthropic; audio never leaves your Mac.",
                      prominent: true) { model.chooseClaude() }
            optionRow(title: "Download a local model",
                      detail: "\(recommendedCatalogModel.diskSize) download. Private: stays on this Mac and works offline.",
                      prominent: false) { model.downloadLocal(settings: settings) }
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

    private func optionRow(title: String, detail: String, prominent: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Dorado.barlowBold(14)).foregroundStyle(Dorado.midnight)
                Text(detail).font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if prominent {
                Button("Choose", action: action).buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button("Choose", action: action).controlSize(.small)
            }
        }
        .padding(12)
        .cardStyle(cornerRadius: 10)
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

    private func installPrompt(outdated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(outdated ? "Claude Code needs an update" : "Claude sign-in needs Claude Code")
                .font(Dorado.barlowBold(14)).foregroundStyle(Dorado.midnight)
            Text("MeetMouse signs in through Claude Code, Anthropic's own app, so your login stays with Anthropic. \(outdated ? "The version on this Mac is too old." : "It isn't on this Mac yet.") Installing runs Anthropic's official installer (claude.ai/install.sh). It goes in your home folder and doesn't ask for your password.")
                .font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(outdated ? "Update Claude Code" : "Install Claude Code") { model.installClaudeCode() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Back") { model.back() }.controlSize(.small)
            }
        }
    }

    private func installFailed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(message) Nothing else on your Mac was changed.")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Try again") { model.installClaudeCode() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Link("Install it yourself ↗", destination: ClaudeAccount.installDocsURL).font(.caption)
                Button("Back") { model.back() }.controlSize(.small)
            }
        }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Signed in to Claude", systemImage: "checkmark.circle.fill")
                .font(Dorado.barlowBold(14)).foregroundStyle(Dorado.midnight)
            Text("To write notes, MeetMouse sends meeting text (never audio) to Anthropic through your Claude account. It counts against your Claude plan's limits. MeetMouse does not store your Claude login.")
                .font(Dorado.roboto(12)).foregroundStyle(Dorado.grey600)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Allow MeetMouse to send meeting text to Claude", isOn: $model.consent)
                .font(Dorado.roboto(12))
                .disabled(model.step == .enabling)
            HStack(spacing: 8) {
                Button(model.step == .enabling ? "Turning on…" : "Turn on AI notes") {
                    model.enableClaude(settings: settings, onReady: announce)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!model.consent || model.step == .enabling)
                Button("Back") { model.back() }.controlSize(.small)
                    .disabled(model.step == .enabling)
            }
        }
    }
}

/// The home screen card shown until an AI provider is working.
struct AISetupCard: View {
    var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up AI notes").font(Dorado.barlowBold(17)).foregroundStyle(Dorado.midnight)
                Text("Right now you only get a basic recap after each call. Pick one way to get full AI notes, summaries and follow-ups.")
                    .font(Dorado.roboto(13)).foregroundStyle(Dorado.grey600)
                    .fixedSize(horizontal: false, vertical: true)
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
            Text("Pick one. You can change it later in Settings.")
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
