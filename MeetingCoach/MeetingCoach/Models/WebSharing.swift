import CryptoKit
import Foundation
import Darwin

// MARK: - The deliberately narrow wire model

/// A topic in the curated meeting notes. The web payload has no transcript,
/// coaching, talk-ratio, or audio fields by construction.
struct SharedNoteSection: Codable, Equatable, Sendable {
    let heading: String
    let bullets: [String]
}

struct SharedNoteAction: Codable, Equatable, Sendable {
    let text: String
    let isDone: Bool
}

/// The complete plaintext that is encrypted before it leaves the Mac.
/// Keep this type intentionally boring and explicit: adding a field here is
/// a privacy decision that should be visible in review and tests.
struct SharedNotePayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let title: String
    let meetingDate: String
    let durationMinutes: Int?
    let summary: String
    let sections: [SharedNoteSection]
    let nextSteps: [SharedNoteAction]

    static func make(title: String,
                     date: Date,
                     durationMinutes: Int,
                     review: MeetingReview) -> SharedNotePayload? {
        // This gate is part of the privacy boundary, not just UI polish.
        // Older/deterministic reviews reuse `summary`, `takeaways`, and
        // `actionItems` for coaching and transcript excerpts. Only the
        // dedicated topic-note shape is eligible for the web snapshot.
        guard review.hasShareableMeetingNotes else { return nil }
        let topics = review.sections.map {
            SharedNoteSection(heading: $0.heading, bullets: $0.bullets)
        }
        return SharedNotePayload(
            schemaVersion: 1,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            meetingDate: date.ISO8601Format(),
            durationMinutes: durationMinutes > 0 ? durationMinutes : nil,
            summary: review.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            sections: topics,
            nextSteps: review.actionItems.map {
                SharedNoteAction(text: $0.text, isDone: $0.isDone)
            }
        )
    }
}

// MARK: - Encryption

struct EncryptedSharedNote: Equatable, Sendable {
    let id: String
    let nonce: String
    /// AES-GCM ciphertext followed by its 16-byte authentication tag.
    let ciphertext: String
    /// URL-fragment secret. It is never included in the upload request.
    let key: String
    /// Owner capability. The server stores only `revokeHash`.
    let revokeToken: String
    let revokeHash: String
}

enum WebShareCrypto {
    static let schemaVersion = 1
    private static let tagByteCount = 16

    static func encrypt(_ payload: SharedNotePayload) throws -> EncryptedSharedNote {
        let id = base64URL(randomBytes(count: 16))
        let keyData = randomBytes(count: 32)
        let revokeToken = base64URL(randomBytes(count: 32))
        return try encrypt(payload, id: id, keyData: keyData,
                           revokeToken: revokeToken)
    }

    /// Deterministic inputs make the crypto contract testable without ever
    /// weakening the production random-number path above.
    static func encrypt(_ payload: SharedNotePayload,
                        id: String,
                        keyData: Data,
                        revokeToken: String) throws -> EncryptedSharedNote {
        guard keyData.count == 32 else { throw WebShareError.invalidEncryptionKey }
        let plaintext = try JSONEncoder().encode(payload)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(plaintext, using: key,
                                      authenticating: authenticatedData(for: id))
        var ciphertextAndTag = sealed.ciphertext
        ciphertextAndTag.append(sealed.tag)
        let revokeDigest = SHA256.hash(data: Data(revokeToken.utf8))
        return EncryptedSharedNote(
            id: id,
            nonce: base64URL(Data(sealed.nonce)),
            ciphertext: base64URL(ciphertextAndTag),
            key: base64URL(keyData),
            revokeToken: revokeToken,
            revokeHash: base64URL(Data(revokeDigest))
        )
    }

    /// Used by the headless contract test. Production decryption happens in
    /// the recipient's browser with the same AES-GCM/AAD wire format.
    static func decrypt(nonce: String, ciphertext: String,
                        key: String, id: String) throws -> SharedNotePayload {
        guard let nonceData = dataFromBase64URL(nonce),
              let combined = dataFromBase64URL(ciphertext),
              let keyData = dataFromBase64URL(key),
              keyData.count == 32,
              combined.count > tagByteCount else {
            throw WebShareError.invalidEncryptedPayload
        }
        let ciphertextData = combined.dropLast(tagByteCount)
        let tag = combined.suffix(tagByteCount)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                       ciphertext: ciphertextData, tag: tag)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyData),
                                        authenticating: authenticatedData(for: id))
        return try JSONDecoder().decode(SharedNotePayload.self, from: plaintext)
    }

    private static func authenticatedData(for id: String) -> Data {
        Data("meetingcoach-share-v\(schemaVersion):\(id)".utf8)
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }
}

// MARK: - API and local owner capability

struct WebShareConfiguration: Sendable {
    let apiBaseURL: URL
    let viewerBaseURL: URL

    static var current: WebShareConfiguration {
        // Use the established HTTPS service in both dev and release. Publishing
        // still happens only when the user explicitly chooses Share notes.
        let apiFallback = "https://rhinovoice.app/api/shared-notes"
        let viewerFallback = "https://rhinovoice.app/p"
        let environment = ProcessInfo.processInfo.environment
        let api = environment["MC_SHARE_API_BASE_URL"] ?? apiFallback
        let viewer = environment["MC_SHARE_VIEWER_BASE_URL"] ?? viewerFallback
        return WebShareConfiguration(apiBaseURL: URL(string: api) ?? URL(string: apiFallback)!,
                                     viewerBaseURL: URL(string: viewer) ?? URL(string: viewerFallback)!)
    }
}

struct SharedLinkRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { shareID }
    let shareID: String
    let sessionPath: String
    let privateURL: String
    let revokeToken: String
    let createdAt: Date
    let expiresAt: Date

    var pending: Bool? = nil
    var apiBaseURL: String? = nil
    var title: String? = nil

    var url: URL? { URL(string: privateURL) }
    var isExpired: Bool { expiresAt <= Date() }
}

actor SharedLinksStore {
    static let shared = SharedLinksStore(storageURL: AppSupport.sharedLinksURL)

    private let storageURL: URL
    init(storageURL: URL) {
        self.storageURL = storageURL
    }

    // The separate lock file keeps the lock stable while atomic writes rename JSON.
    // Every reader/writer reloads under this cross-process lock, including dev builds.
    private func transaction<T>(_ update: (inout [SharedLinkRecord]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(storageURL.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        var records: [SharedLinkRecord] = []
        if FileManager.default.fileExists(atPath: storageURL.path) {
            records = try JSONDecoder().decode([SharedLinkRecord].self,
                                               from: Data(contentsOf: storageURL))
        }
        let previous = records
        let result = try update(&records)
        if previous != records {
            try JSONEncoder().encode(records).write(to: storageURL, options: .atomic)
        }
        return result
    }

    func allRecords(now: Date = Date()) throws -> [SharedLinkRecord] {
        try transaction { records in
            // Pending requests may have reached the server later than our clock.
            // Retain their capability until the owner explicitly resolves them.
            records.removeAll { $0.pending != true && $0.expiresAt <= now }
            return records.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func record(for sessionURL: URL, now: Date = Date()) throws -> SharedLinkRecord? {
        try allRecords(now: now).first { $0.sessionPath == sessionURL.standardizedFileURL.path }
    }

    func save(_ record: SharedLinkRecord) throws {
        try transaction { records in
            records.removeAll { $0.shareID == record.shareID }
            records.append(record)
        }
    }

    func remove(_ record: SharedLinkRecord) throws {
        try transaction { records in records.removeAll { $0.shareID == record.shareID } }
    }

}

struct WebShareService: Sendable {
    private struct CreateRequest: Codable {
        let schemaVersion: Int
        let id: String
        let nonce: String
        let ciphertext: String
        let revokeHash: String
    }

    private struct CreateResponse: Codable {
        let id: String
        let expiresAt: Int64
    }

    let configuration: WebShareConfiguration
    let store: SharedLinksStore
    let session: URLSession

    init(configuration: WebShareConfiguration = .current,
         store: SharedLinksStore = .shared, session: URLSession = .shared) {
        self.configuration = configuration
        self.store = store
        self.session = session
    }

    func create(payload: SharedNotePayload, sessionURL: URL) async throws -> SharedLinkRecord {
        let encrypted = try WebShareCrypto.encrypt(payload)
        let body = CreateRequest(schemaVersion: WebShareCrypto.schemaVersion,
                                 id: encrypted.id,
                                 nonce: encrypted.nonce,
                                 ciphertext: encrypted.ciphertext,
                                 revokeHash: encrypted.revokeHash)
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("create"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 15

        var components = URLComponents(
            url: configuration.viewerBaseURL.appendingPathComponent(encrypted.id),
            resolvingAgainstBaseURL: false
        )!
        components.fragment = encrypted.key
        guard let privateURL = components.url else { throw WebShareError.invalidServerResponse }
        var record = SharedLinkRecord(
            shareID: encrypted.id,
            sessionPath: sessionURL.standardizedFileURL.path,
            privateURL: privateURL.absoluteString,
            revokeToken: encrypted.revokeToken,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
            pending: true,
            apiBaseURL: configuration.apiBaseURL.absoluteString,
            title: payload.title
        )
        // No upload until recovery controls are durable. On any ambiguous failure,
        // leave this record available in Shared links, including after relaunch.
        try await store.save(record)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else { throw serverError(status: status, data: data) }
        let created = try JSONDecoder().decode(CreateResponse.self, from: data)
        guard created.id == encrypted.id else { throw WebShareError.invalidServerResponse }
        record = SharedLinkRecord(shareID: record.shareID, sessionPath: record.sessionPath,
                                 privateURL: record.privateURL, revokeToken: record.revokeToken,
                                 createdAt: record.createdAt,
                                 expiresAt: Date(timeIntervalSince1970: TimeInterval(created.expiresAt)),
                                 pending: false, apiBaseURL: record.apiBaseURL, title: record.title)
        try await store.save(record)
        return record
    }

    func revoke(_ record: SharedLinkRecord) async throws {
        var request = URLRequest(
            url: (record.apiBaseURL.flatMap(URL.init(string:)) ?? configuration.apiBaseURL)
                .appendingPathComponent(record.shareID)
        )
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(record.revokeToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Missing/expired is already no longer shared, so it is a successful
        // outcome from the owner's point of view.
        guard status == 204 || status == 404 || status == 410 else {
            throw serverError(status: status, data: data)
        }
    }

    private func serverError(status: Int, data: Data) -> WebShareError {
        struct ErrorBody: Decodable { let error: String }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        return .server(status: status, message: message)
    }
}

enum WebShareError: Error, LocalizedError, Sendable {
    case invalidEncryptionKey
    case invalidEncryptedPayload
    case invalidServerResponse
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEncryptionKey:
            return "The private-link encryption key was invalid."
        case .invalidEncryptedPayload:
            return "The encrypted note was invalid."
        case .invalidServerResponse:
            return "The sharing service returned an invalid response."
        case let .server(status, message):
            if let message, !message.isEmpty { return message }
            return "The sharing service returned HTTP \(status)."
        }
    }
}
