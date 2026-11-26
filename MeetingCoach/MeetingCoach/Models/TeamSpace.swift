import CryptoKit
import Foundation

// Team space: one private page per team (meetmouse.com/t/<id>#<secret>)
// where members put the notes they choose to share.
//
// The team secret is 32 random bytes that exist only in the invite link and
// on members' Macs. Two values are derived from it with HMAC-SHA256:
//   - an access token, sent as a Bearer token (the server keeps its hash);
//   - the AES-GCM key every note and the team name are sealed with.
// The server therefore stores ciphertext it cannot read. The same derivation
// runs in the team page's script (web-share/src/team.js.txt) and is pinned
// by shared test vectors (tests/team, web-share/test/teams.test.mjs).
//
// What reaches the team page is the same curated payload as a private link
// (no transcript, coaching or talk stats). Joining a team opts the member
// in: notes for meetings recorded after joining are shared when they are
// ready. The member can turn that off in Settings, take any meeting off the
// page, and share older meetings by hand.

// MARK: - Invite link

struct TeamInvite: Equatable, Sendable {
    let teamID: String
    /// base64url of the 32-byte team secret.
    let secret: String

    /// Accepts the team page link (https://meetmouse.com/t/<id>#<secret>)
    /// or the app link the page's "Open in MeetMouse" button uses
    /// (meetmouse://team?id=<id>&key=<secret>).
    static func parse(_ text: String) -> TeamInvite? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return nil }
        let teamID: String?
        let secret: String?
        if components.scheme == "meetmouse" {
            guard components.host == "team" else { return nil }
            teamID = components.queryItems?.first { $0.name == "id" }?.value
            secret = components.queryItems?.first { $0.name == "key" }?.value
        } else {
            let parts = components.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[parts.count - 2] == "t" else { return nil }
            teamID = parts.last
            secret = components.fragment
        }
        guard let teamID, let secret, isValidID(teamID),
              WebShareCrypto.dataFromBase64URL(secret)?.count == 32 else { return nil }
        return TeamInvite(teamID: teamID, secret: secret)
    }

    static func isValidID(_ id: String) -> Bool {
        id.count == 22 && id.unicodeScalars.allSatisfy {
            ($0.value < 128 && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }
}

// MARK: - Crypto

enum TeamCrypto {
    static let maxSealedNoteBytes = 64 * 1024

    static func derive(_ secret: Data, _ label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8),
                                             using: SymmetricKey(data: secret)))
    }

    static func accessToken(secret: Data) -> String {
        WebShareCrypto.base64URL(derive(secret, "meetmouse-team-access-v1"))
    }

    /// What the server stores: SHA-256 of the access token's text.
    static func accessHash(secret: Data) -> String {
        WebShareCrypto.base64URL(Data(SHA256.hash(data: Data(accessToken(secret: secret).utf8))))
    }

    static func notesKey(secret: Data) -> Data {
        derive(secret, "meetmouse-team-notes-v1")
    }

    /// Stable per member and meeting, so sharing a meeting again replaces
    /// its note on the team page instead of adding a second one.
    static func noteID(secret: Data, memberID: String, sessionFile: String) -> String {
        WebShareCrypto.base64URL(derive(secret, "note:\(memberID):\(sessionFile)").prefix(16))
    }

    private static func authenticatedData(teamID: String, context: String) -> Data {
        Data("meetmouse-team-v1:\(teamID):\(context)".utf8)
    }

    /// `context` binds the ciphertext to its slot ("name", or the note id),
    /// so a note can't be replayed under another id. `nonce` is for tests.
    static func seal<Value: Encodable>(_ value: Value, secret: Data, teamID: String,
                                       context: String,
                                       nonce: AES.GCM.Nonce? = nil) throws -> (nonce: String, ciphertext: String) {
        guard secret.count == 32 else { throw TeamError.invalidInvite }
        let plaintext = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plaintext,
                                      using: SymmetricKey(data: notesKey(secret: secret)),
                                      nonce: nonce ?? AES.GCM.Nonce(),
                                      authenticating: authenticatedData(teamID: teamID, context: context))
        var body = sealed.ciphertext
        body.append(sealed.tag)
        return (WebShareCrypto.base64URL(Data(sealed.nonce)), WebShareCrypto.base64URL(body))
    }

    static func unseal<Value: Decodable>(_ type: Value.Type, nonce: String, ciphertext: String,
                                         secret: Data, teamID: String,
                                         context: String) throws -> Value {
        guard let nonceData = WebShareCrypto.dataFromBase64URL(nonce),
              let body = WebShareCrypto.dataFromBase64URL(ciphertext),
              body.count > 16, secret.count == 32 else { throw TeamError.unreadable }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                       ciphertext: body.dropLast(16), tag: body.suffix(16))
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: notesKey(secret: secret)),
                                        authenticating: authenticatedData(teamID: teamID, context: context))
        return try JSONDecoder().decode(type, from: plaintext)
    }

    static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

// MARK: - Wire and local models

struct TeamName: Codable, Equatable, Sendable {
    let name: String
}

/// What a teammate can read: who shared it, plus the same curated notes a
/// private link carries. Adding a field here is a privacy decision.
struct TeamNotePayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let author: String
    let note: SharedNotePayload
}

/// This Mac's place in a team. Stored in Application Support, readable only
/// by the user; the secret is the whole capability, like a private link's key.
struct TeamMembership: Codable, Equatable, Sendable {
    let teamID: String
    let secret: String
    var teamName: String
    var memberName: String
    /// Random per install; only feeds note ids, never sent on its own.
    let memberID: String
    /// Session file name → note id on the team page.
    var shared: [String: String] = [:]
    var apiBaseURL: String
    var pageBaseURL: String
    /// Team sharing is on by default: notes for meetings recorded after
    /// joining go to the team page when they're ready. nil means on; the
    /// member turns it off in Settings → Team.
    var autoShare: Bool? = nil
    /// When this Mac joined. Older meetings are never shared automatically.
    var joinedAt: Date? = nil
    /// Meetings the member took off the team page (or chose not to share):
    /// automatic sharing leaves these alone.
    var excluded: [String]? = nil

    var sharesAutomatically: Bool { autoShare ?? true }

    /// Whether this meeting's notes should go to the team page on their own.
    func shouldAutoShare(sessionFile: String, sessionDate: Date?) -> Bool {
        guard sharesAutomatically, shared[sessionFile] == nil,
              !(excluded ?? []).contains(sessionFile),
              let joinedAt, let sessionDate else { return false }
        // The file's date is its start, to the minute; allow a meeting that
        // was already running when this Mac joined.
        return sessionDate >= joinedAt.addingTimeInterval(-4 * 3600)
    }

    var secretData: Data { WebShareCrypto.dataFromBase64URL(secret) ?? Data() }

    /// The team page; also the invite link.
    var inviteLink: String { "\(pageBaseURL)/\(teamID)#\(secret)" }
    var pageURL: URL? { URL(string: inviteLink) }

    func noteID(forSessionFile file: String) -> String {
        TeamCrypto.noteID(secret: secretData, memberID: memberID, sessionFile: file)
    }
}

struct TeamStore: Sendable {
    let storageURL: URL

    static var standard: TeamStore {
        TeamStore(storageURL: AppSupport.root.appendingPathComponent("team.json"))
    }

    func load() -> TeamMembership? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode(TeamMembership.self, from: data)
    }

    func save(_ membership: TeamMembership) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(membership).write(to: storageURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: storageURL.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: storageURL)
    }

    // Teams this Mac was on before. Leaving or switching keeps the old
    // membership here, so the invite link isn't lost and re-joining gets
    // back the same member id and the list of what was shared (without it,
    // earlier notes could no longer be updated or removed from the app).

    private var archiveURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent(
            storageURL.deletingPathExtension().lastPathComponent + "-previous.json")
    }

    func archived() -> [TeamMembership] {
        guard let data = try? Data(contentsOf: archiveURL) else { return [] }
        return (try? JSONDecoder().decode([TeamMembership].self, from: data)) ?? []
    }

    func archived(teamID: String, secret: String) -> TeamMembership? {
        archived().first { $0.teamID == teamID && $0.secret == secret }
    }

    func archive(_ membership: TeamMembership) {
        var all = archived().filter { $0.teamID != membership.teamID }
        all.append(membership)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: archiveURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: archiveURL.path)
    }
}

enum TeamError: Error, LocalizedError, Equatable, Sendable {
    case invalidInvite
    case notFound
    case wrongLink
    case unreadable
    case noteTooLarge
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidInvite:
            return "That doesn't look like a MeetMouse team invite link. Ask a teammate to copy it again from Settings or the team page."
        case .notFound:
            return "That team wasn't found. Ask a teammate for the invite link again."
        case .wrongLink:
            return "That invite link doesn't match the team. Part of it may be missing; ask a teammate to copy the complete link."
        case .unreadable:
            return "The team page sent something MeetMouse couldn't read."
        case .noteTooLarge:
            return "These notes are too long for the team page (64 KB limit)."
        case let .server(status, message):
            if let message, !message.isEmpty { return message }
            return "The team service returned HTTP \(status)."
        }
    }
}

// MARK: - Service

struct TeamService: Sendable {
    let apiBaseURL: URL
    let pageBaseURL: String
    let session: URLSession

    init(apiBaseURL: URL? = nil, pageBaseURL: String? = nil, session: URLSession = .shared) {
        // Same host as private links; overridable for local Worker testing.
        let environment = ProcessInfo.processInfo.environment
        let apiFallback = URL(string: "https://meetmouse.com/api/teams")!
        self.apiBaseURL = apiBaseURL
            ?? environment["MC_TEAM_API_BASE_URL"].flatMap(URL.init(string:))
            ?? apiFallback
        self.pageBaseURL = pageBaseURL
            ?? environment["MC_TEAM_PAGE_BASE_URL"]
            ?? "https://meetmouse.com/t"
        self.session = session
    }

    private struct CreateRequest: Encodable {
        let id: String
        let accessHash: String
        let nameNonce: String
        let nameCiphertext: String
    }

    private struct TeamResponse: Decodable {
        let nameNonce: String
        let nameCiphertext: String
    }

    private struct NoteRequest: Encodable {
        let nonce: String
        let ciphertext: String
    }

    func create(teamName: String, memberName: String) async throws -> TeamMembership {
        let teamID = WebShareCrypto.base64URL(TeamCrypto.randomBytes(count: 16))
        let secret = TeamCrypto.randomBytes(count: 32)
        let name = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sealed = try TeamCrypto.seal(TeamName(name: name), secret: secret,
                                         teamID: teamID, context: "name")
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("create"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(CreateRequest(
            id: teamID, accessHash: TeamCrypto.accessHash(secret: secret),
            nameNonce: sealed.nonce, nameCiphertext: sealed.ciphertext))
        _ = try await send(request, secret: nil, expecting: [201])
        return membership(teamID: teamID, secret: WebShareCrypto.base64URL(secret),
                          teamName: name, memberName: memberName)
    }

    /// Checks the invite against the server and reads the team's name.
    func join(_ invite: TeamInvite, memberName: String) async throws -> TeamMembership {
        guard let secret = WebShareCrypto.dataFromBase64URL(invite.secret), secret.count == 32 else {
            throw TeamError.invalidInvite
        }
        let request = URLRequest(url: apiBaseURL.appendingPathComponent(invite.teamID))
        let data = try await send(request, secret: secret, expecting: [200])
        guard let team = try? JSONDecoder().decode(TeamResponse.self, from: data),
              let name = try? TeamCrypto.unseal(TeamName.self, nonce: team.nameNonce,
                                                ciphertext: team.nameCiphertext, secret: secret,
                                                teamID: invite.teamID, context: "name") else {
            throw TeamError.unreadable
        }
        return membership(teamID: invite.teamID, secret: invite.secret,
                          teamName: name.name, memberName: memberName)
    }

    /// Puts (or replaces) one meeting's curated notes on the team page.
    /// Returns the note id to remember for that meeting.
    func share(_ note: SharedNotePayload, sessionFile: String,
               as membership: TeamMembership) async throws -> String {
        let noteID = membership.noteID(forSessionFile: sessionFile)
        let payload = TeamNotePayload(schemaVersion: 1,
                                      author: membership.memberName, note: note)
        let sealed = try TeamCrypto.seal(payload, secret: membership.secretData,
                                         teamID: membership.teamID, context: noteID)
        guard (WebShareCrypto.dataFromBase64URL(sealed.ciphertext)?.count ?? .max)
                <= TeamCrypto.maxSealedNoteBytes else { throw TeamError.noteTooLarge }
        var request = URLRequest(url: noteURL(membership, noteID))
        request.httpMethod = "PUT"
        request.httpBody = try JSONEncoder().encode(
            NoteRequest(nonce: sealed.nonce, ciphertext: sealed.ciphertext))
        _ = try await send(request, secret: membership.secretData, expecting: [200, 201])
        return noteID
    }

    func remove(noteID: String, as membership: TeamMembership) async throws {
        var request = URLRequest(url: noteURL(membership, noteID))
        request.httpMethod = "DELETE"
        _ = try await send(request, secret: membership.secretData, expecting: [204])
    }

    private func noteURL(_ membership: TeamMembership, _ noteID: String) -> URL {
        (URL(string: membership.apiBaseURL) ?? apiBaseURL)
            .appendingPathComponent(membership.teamID)
            .appendingPathComponent("notes")
            .appendingPathComponent(noteID)
    }

    private func membership(teamID: String, secret: String,
                            teamName: String, memberName: String) -> TeamMembership {
        TeamMembership(teamID: teamID, secret: secret, teamName: teamName,
                       memberName: memberName.trimmingCharacters(in: .whitespacesAndNewlines),
                       memberID: WebShareCrypto.base64URL(TeamCrypto.randomBytes(count: 12)),
                       apiBaseURL: apiBaseURL.absoluteString, pageBaseURL: pageBaseURL,
                       joinedAt: Date())
    }

    private func send(_ original: URLRequest, secret: Data?,
                      expecting: Set<Int>) async throws -> Data {
        var request = original
        request.timeoutInterval = 15
        if request.httpBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let secret {
            request.setValue("Bearer \(TeamCrypto.accessToken(secret: secret))",
                             forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if expecting.contains(status) { return data }
        if status == 404 { throw TeamError.notFound }
        if status == 401 || status == 403 { throw TeamError.wrongLink }
        struct ErrorBody: Decodable { let error: String }
        throw TeamError.server(status: status,
                               message: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
    }
}
