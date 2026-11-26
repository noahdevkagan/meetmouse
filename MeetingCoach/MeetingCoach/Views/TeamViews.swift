import AppKit
import SwiftUI

/// This Mac's team membership, for SwiftUI. See Models/TeamSpace.swift for
/// what a team is and what leaves the Mac.
@MainActor @Observable
final class TeamSpace {
    static let shared = TeamSpace()

    private(set) var membership: TeamMembership?
    private let store: TeamStore
    private let service: TeamService

    init(store: TeamStore = .standard, service: TeamService = TeamService()) {
        self.store = store
        self.service = service
        membership = store.load()
        // Posted when a meeting's notes are written (live review finished,
        // or notes generated on a saved meeting). See `autoShare`.
        NotificationCenter.default.addObserver(
            forName: Self.notesReady, object: nil, queue: .main
        ) { [weak self] note in
            guard let path = note.userInfo?["path"] as? String else { return }
            Task { @MainActor [weak self] in
                await self?.autoShare(sessionURL: URL(fileURLWithPath: path))
            }
        }
    }

    /// Same name the live session and the meeting page post (kept as a raw
    /// string there so they don't depend on this file).
    static let notesReady = Notification.Name("MeetMouse.meetingNotesReady")

    /// Team sharing is default-on: when a meeting recorded after joining
    /// gets its AI notes, they go to the team page. Quiet on failure; the
    /// Share with team button on the meeting stays available.
    func autoShare(sessionURL: URL) async {
        guard let current = membership,
              current.shouldAutoShare(sessionFile: sessionURL.lastPathComponent,
                                      sessionDate: TranscriptSearch.sessionDate(for: sessionURL)),
              let content = try? String(contentsOf: sessionURL, encoding: .utf8),
              let review = MeetingNotesFile.review(in: content),
              let meta = TranscriptStore.metadataByParsing(sessionURL),
              let payload = SharedNotePayload.make(
                  title: meta.title ?? "Meeting notes", date: meta.startedAt,
                  durationMinutes: Int(meta.durationMin.rounded()), review: review)
        else { return }
        try? await share(payload, sessionURL: sessionURL)
    }

    func setAutoShare(_ on: Bool) {
        guard var current = membership else { return }
        current.autoShare = on
        try? store.save(current)
        membership = current
    }

    static var defaultMemberName: String {
        let name = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? NSUserName() : name
    }

    /// A team license ($40 once, unlimited seats) is bought by one person:
    /// their team code lets this Mac create the team, members unlock by joining.
    var canCreateTeam: Bool { FreeTier.shared.hasTeamLicense }

    static let buyURL = URL(string: "https://meetmouse.com/team")!

    func create(teamName: String, memberName: String) async throws {
        let created = try await service.create(teamName: teamName, memberName: memberName)
        try store.save(created)
        membership = created
    }

    func join(link: String, memberName: String) async throws {
        guard let invite = TeamInvite.parse(link) else { throw TeamError.invalidInvite }
        try await join(invite, memberName: memberName)
    }

    private func join(_ invite: TeamInvite, memberName: String) async throws {
        let checked = try await service.join(invite, memberName: memberName)
        try commit(checked)
    }

    /// Makes a membership the server has confirmed the current one.
    private func commit(_ checked: TeamMembership) throws {
        var joined = checked
        // Re-joining a team (still on it, or one this Mac left) keeps the
        // member id and the record of what was shared.
        let known = [membership, store.archived(teamID: joined.teamID, secret: joined.secret)]
            .compactMap { $0 }
            .first { $0.teamID == joined.teamID && $0.secret == joined.secret }
        if let known {
            joined = TeamMembership(teamID: known.teamID, secret: known.secret,
                                    teamName: joined.teamName, memberName: joined.memberName,
                                    memberID: known.memberID, shared: known.shared,
                                    apiBaseURL: joined.apiBaseURL, pageBaseURL: joined.pageBaseURL,
                                    autoShare: known.autoShare,
                                    joinedAt: known.joinedAt ?? joined.joinedAt,
                                    excluded: known.excluded)
        }
        if let current = membership, current.teamID != joined.teamID { store.archive(current) }
        try store.save(joined)
        membership = joined
        FreeTier.shared.unlockViaTeam()
    }

    /// Takes this Mac off the team. Notes already on the team page stay
    /// there for the team; remove them first to take them down. The
    /// membership is kept aside so joining again restores it.
    func leave() {
        if let membership { store.archive(membership) }
        store.clear()
        membership = nil
    }

    /// A deleted meeting's team copy comes down with it (best effort): its
    /// only "Remove from team page" control is on the meeting being deleted.
    func meetingDeleted(_ sessionURL: URL) {
        guard isShared(sessionURL) else { return }
        Task { try? await self.unshare(sessionURL: sessionURL) }
    }

    func isShared(_ sessionURL: URL) -> Bool {
        membership?.shared[sessionURL.lastPathComponent] != nil
    }

    func share(_ note: SharedNotePayload, sessionURL: URL) async throws {
        guard var current = membership else { return }
        let file = sessionURL.lastPathComponent
        let noteID = try await service.share(note, sessionFile: file, as: current)
        // The membership may have changed while the request was in flight.
        guard membership?.teamID == current.teamID else { return }
        current = membership ?? current
        current.shared[file] = noteID
        current.excluded?.removeAll { $0 == file }
        try store.save(current)
        membership = current
    }

    func unshare(sessionURL: URL) async throws {
        guard var current = membership else { return }
        let file = sessionURL.lastPathComponent
        guard let noteID = current.shared[file] else { return }
        try await service.remove(noteID: noteID, as: current)
        guard membership?.teamID == current.teamID else { return }
        current = membership ?? current
        current.shared[file] = nil
        // Taken down on purpose: automatic sharing must not put it back.
        if !(current.excluded ?? []).contains(file) {
            current.excluded = (current.excluded ?? []) + [file]
        }
        try store.save(current)
        membership = current
    }

    func copyInviteLink() {
        guard let link = membership?.inviteLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    /// meetmouse://team?id=…&key=… — asks first, then joins.
    func handleInvite(_ url: URL) {
        guard let invite = TeamInvite.parse(url.absoluteString) else {
            alert("That team link didn't work",
                  "Open Settings and paste the invite link under Team instead.")
            return
        }
        if let current = membership, current.teamID == invite.teamID {
            alert("You're already on \(current.teamName)",
                  "Nothing to do. Manage sharing in Settings, under Team.")
            return
        }
        // Look the team up first so the question can name it: a link can be
        // opened by any web page, and joining decides where notes go.
        Task {
            do {
                let checked = try await self.service.join(invite, memberName: Self.defaultMemberName)
                let confirm = NSAlert()
                confirm.messageText = "Join the team \u{201C}\(checked.teamName)\u{201D}?"
                if let current = self.membership {
                    confirm.informativeText = "This Mac is on \u{201C}\(current.teamName)\u{201D} now and will switch: notes for your meetings from now on will go to \u{201C}\(checked.teamName)\u{201D} instead. You can turn automatic sharing off in Settings. Only join a team you were invited to by someone you know."
                } else {
                    confirm.informativeText = "From now on, the notes MeetMouse writes for your meetings (summary, topics, next steps) are shared to this team's page. Transcripts and coaching stay on this Mac. You can turn this off in Settings, or take any meeting off the page. Only join a team you were invited to by someone you know."
                }
                confirm.addButton(withTitle: "Join")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
                try self.commit(checked)
                self.alert("You joined \(checked.teamName)",
                           "MeetMouse is unlocked on this Mac. Notes for your meetings from now on are shared with the team; change that in Settings, under Team.")
            } catch {
                self.alert("Couldn't join the team", error.localizedDescription)
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Settings

struct TeamSettingsSection: View {
    @State private var team = TeamSpace.shared
    @State private var memberName = TeamSpace.defaultMemberName
    @State private var teamName = ""
    @State private var inviteLink = ""
    @State private var teamCode = ""
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmingLeave = false

    var body: some View {
        Section("Team") {
            if let membership = team.membership {
                LabeledContent("Team") { Text(membership.teamName) }
                LabeledContent("Sharing as") { Text(membership.memberName) }
                Toggle("Share my meeting notes with the team automatically", isOn: Binding(
                    get: { team.membership?.sharesAutomatically ?? true },
                    set: { team.setAutoShare($0) }))
                HStack {
                    if let url = membership.pageURL {
                        ShareLink(item: url,
                                  subject: Text("Join \(membership.teamName) on MeetMouse"),
                                  message: Text("Join our MeetMouse team so our meeting notes land in one place. Open this link and click Open in MeetMouse (it also unlocks MeetMouse on your Mac):")) {
                            Label("Invite people…", systemImage: "person.badge.plus")
                        }
                    }
                    Button("Copy invite link") {
                        team.copyInviteLink()
                        show("Invite link copied. Send it only to your team.")
                    }
                    Button("Open team page") {
                        if let url = membership.pageURL { NSWorkspace.shared.open(url) }
                    }
                    Button("Leave team…") { confirmingLeave = true }
                }
                .confirmationDialog("Leave \(membership.teamName)?", isPresented: $confirmingLeave,
                                    titleVisibility: .visible) {
                    Button("Leave team", role: .destructive) {
                        team.leave()
                        message = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This Mac leaves the team. Notes you already shared stay on the team page; remove them from each meeting first if you want them gone. Joining again with the invite link brings your shared list back.")
                }
                statusLine
                Text("While this is on, notes for meetings you record from now on go to the team page as soon as they're written. Teammates get the notes (summary, topics, next steps), never the transcript or coaching. Take any meeting off the page from its Shared with team menu, and share older meetings with Share with team. Notes are encrypted on this Mac and stay on the team page for a year. Anyone with the invite link can read and add notes, and joining unlocks MeetMouse for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Your name", text: $memberName)
                if team.canCreateTeam {
                    HStack {
                        TextField("Team name", text: $teamName)
                        Button("Create team") { create() }
                            .disabled(busy || trimmed(teamName).isEmpty || trimmed(memberName).isEmpty)
                    }
                } else {
                    HStack {
                        TextField("Team code (TEAM-…)", text: $teamCode)
                            .onSubmit { redeemTeamCode() }
                        Button("Unlock") { redeemTeamCode() }
                            .disabled(trimmed(teamCode).isEmpty)
                        Button("Buy a team license: $40") { NSWorkspace.shared.open(TeamSpace.buyURL) }
                    }
                }
                HStack {
                    TextField("Invite link from a teammate", text: $inviteLink)
                        .onSubmit { join() }
                    Button("Join") { join() }
                        .disabled(busy || trimmed(inviteLink).isEmpty || trimmed(memberName).isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                }
                statusLine
                Text(team.canCreateTeam
                     ? "A team gets one private page where everyone's meeting notes live. Create the team, then invite your teammates; joining unlocks MeetMouse on their Macs. Once on a team, notes for new meetings are shared automatically (you can turn that off)."
                     : "A team gets one private page where everyone's shared meeting notes live. Starting a team takes a team license: $40 once, unlimited seats, bought by one person. Teammates don't need a code; joining with the invite link unlocks MeetMouse on their Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(messageIsError ? .red : .secondary)
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func show(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }

    private func redeemTeamCode() {
        guard !trimmed(teamCode).isEmpty else { return }
        if FreeTier.shared.unlock(code: teamCode), team.canCreateTeam {
            teamCode = ""
            show("Team license is on. Name your team and click Create team.")
        } else {
            show("That isn't a team code. It starts with TEAM- and is on the page you saw after paying.", isError: true)
        }
    }

    private func create() {
        busy = true
        message = nil
        Task {
            do {
                try await team.create(teamName: teamName, memberName: memberName)
                team.copyInviteLink()
                show("Team created and the invite link is copied. Paste it to your teammates, or click Invite people.")
                teamName = ""
            } catch {
                show(error.localizedDescription, isError: true)
            }
            busy = false
        }
    }

    private func join() {
        guard !busy, !trimmed(inviteLink).isEmpty else { return }
        busy = true
        message = nil
        Task {
            do {
                try await team.join(link: inviteLink, memberName: memberName)
                show("You're on the team. Notes for your meetings from now on are shared with it; turn that off above if you prefer.")
                inviteLink = ""
            } catch {
                show(error.localizedDescription, isError: true)
            }
            busy = false
        }
    }
}

// MARK: - Meeting page

/// "Share with team" beside Share notes. Hidden when this Mac isn't on a
/// team. `payload` is nil when the meeting has no shareable AI notes yet.
struct TeamShareControl: View {
    let sessionURL: URL
    let payload: SharedNotePayload?

    @State private var team = TeamSpace.shared
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        if let membership = team.membership {
            Group {
                if team.isShared(sessionURL) {
                    Menu {
                        Button("Update team copy") { share() }
                        Button("Copy team invite link") { team.copyInviteLink() }
                        Button("Open team page") {
                            if let url = membership.pageURL { NSWorkspace.shared.open(url) }
                        }
                        Divider()
                        Button("Remove from team page", role: .destructive) { remove() }
                    } label: {
                        label(icon: "checkmark.circle", tint: Dorado.dollar, text: "Shared with team")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Button { share() } label: {
                        label(icon: "person.2", tint: Dorado.grey500, text: "Share with team")
                    }
                }
            }
            .buttonStyle(DoradoOutlineButtonStyle())
            .disabled(busy)
            .help("Put these notes on \(membership.teamName)'s team page. The transcript and coaching stay on this Mac.")
            .alert("Team sharing", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func label(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 7) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            }
            Text(text)
        }
    }

    private func share() {
        guard let payload else {
            errorMessage = "This meeting has no AI notes yet. Generate them on the Notes tab (or click Share notes), then share with the team."
            return
        }
        busy = true
        Task {
            do { try await team.share(payload, sessionURL: sessionURL) }
            catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }

    private func remove() {
        busy = true
        Task {
            do { try await team.unshare(sessionURL: sessionURL) }
            catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
