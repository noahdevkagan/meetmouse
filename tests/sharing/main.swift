import Foundation

private var failed = false

private func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    print("sharing \(label): \(condition ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !condition { failed = true }
}

@main
struct SharingTests {
    static func main() async {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--writer" {
            let store = SharedLinksStore(storageURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            do {
                for index in 0..<20 {
                    let id = CommandLine.arguments[3] + String(index)
                    try await store.save(SharedLinkRecord(shareID: id, sessionPath: "/fixture/" + id,
                        privateURL: "https://test.invalid/" + id, revokeToken: "fixture",
                        createdAt: Date(), expiresAt: Date().addingTimeInterval(3600)))
                }
            } catch { exit(1) }
            return
        }
        var review = MeetingReview(
            title: "Private quarterly plan",
            summary: "The team chose the smaller launch.",
            sections: [ReviewSection(heading: "Launch scope", bullets: ["Ship referrals first."])],
            takeaways: ["Measure recipient opens."],
            actionItems: [ActionItem(text: "Recruit ten testers (Noah)")],
            wins: ["PRIVATE-COACHING-WIN"],
            nextFocus: "PRIVATE-NEXT-FOCUS",
            talkShare: 0.72
        )
        review.actionItems[0].isDone = true

        guard let payload = SharedNotePayload.make(
            title: "Growth planning",
            date: Date(timeIntervalSince1970: 1_789_430_400),
            durationMinutes: 42,
            review: review
        ) else {
            check(false, "topic notes are eligible to share")
            exit(1)
        }
        check(payload.summary == review.summary, "summary enters curated payload")
        check(payload.sections.count == 1 && payload.sections.first?.heading == "Launch scope",
              "only topic notes enter curated payload")
        check(payload.nextSteps.first?.isDone == true, "next-step completion survives")

        let encoded = (try? JSONEncoder().encode(payload)) ?? Data()
        let json = String(data: encoded, encoding: .utf8) ?? ""
        check(!json.contains("PRIVATE-COACHING-WIN")
              && !json.contains("PRIVATE-NEXT-FOCUS")
              && !json.contains("talkShare")
              && !json.contains("transcript")
              && !json.contains("nudge"),
              "coaching, transcript, and talk stats cannot enter wire JSON", json)

        let fallbackReview = MeetingReview(
            summary: "42 min meeting. You spoke 72% of the time.",
            takeaways: ["PRIVATE-COACHING-TAKEAWAY"],
            actionItems: [ActionItem(text: "PRIVATE-TRANSCRIPT-QUOTE")],
            isDeterministic: true
        )
        check(SharedNotePayload.make(
            title: "Fallback review",
            date: Date(),
            durationMinutes: 42,
            review: fallbackReview
        ) == nil, "fallback coaching review cannot become a shared note")

        let reloadedLegacyReview = MeetingReview(
            summary: fallbackReview.summary,
            takeaways: fallbackReview.takeaways,
            actionItems: fallbackReview.actionItems
        )
        check(SharedNotePayload.make(
            title: "Reloaded fallback review",
            date: Date(),
            durationMinutes: 42,
            review: reloadedLegacyReview
        ) == nil, "legacy flat review must be regenerated before sharing")

        let id = "abcdefghijklmnopqrstuv"
        let key = Data(0..<32)
        let token = "test-revoke-token"
        do {
            let encrypted = try WebShareCrypto.encrypt(payload, id: id,
                                                       keyData: key, revokeToken: token)
            check(encrypted.key == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
                  "key uses unpadded base64url")
            check(encrypted.revokeHash == "Wxu4ZkuAmh-UnQfFYokIXKnUDIO04Jr0YcRaKMpAc5o",
                  "revocation hash matches Worker contract", encrypted.revokeHash)
            let opened = try WebShareCrypto.decrypt(
                nonce: encrypted.nonce, ciphertext: encrypted.ciphertext,
                key: encrypted.key, id: encrypted.id
            )
            check(opened == payload, "AES-GCM round trip preserves curated note")
            do {
                _ = try WebShareCrypto.decrypt(nonce: encrypted.nonce,
                                               ciphertext: encrypted.ciphertext,
                                               key: encrypted.key,
                                               id: "wrong-identifier-value")
                check(false, "authenticated id rejects link substitution")
            } catch {
                check(true, "authenticated id rejects link substitution")
            }

            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mc-sharing-\(ProcessInfo.processInfo.processIdentifier)")
            let storeURL = scratch.appendingPathComponent("links.json")
            let sessionURL = scratch.appendingPathComponent("meeting.md")
            let record = SharedLinkRecord(
                shareID: id,
                sessionPath: sessionURL.standardizedFileURL.path,
                privateURL: "https://rhinovoice.app/p/\(id)#\(encrypted.key)",
                revokeToken: token,
                createdAt: Date(timeIntervalSince1970: 100),
                expiresAt: Date(timeIntervalSince1970: 1_000)
            )
            let store = SharedLinksStore(storageURL: storeURL)
            try await store.save(record)
            let reloaded = SharedLinksStore(storageURL: storeURL)
            let found = try await reloaded.record(for: sessionURL,
                                                  now: Date(timeIntervalSince1970: 500))
            check(found == record, "owner capability persists beside app data")
            let expired = try await reloaded.record(for: sessionURL,
                                                    now: Date(timeIntervalSince1970: 1_001))
            check(expired == nil, "expired local share state is removed")
            try? FileManager.default.removeItem(at: scratch)

            if let base = ProcessInfo.processInfo.environment["MC_SHARE_E2E_URL"],
               let baseURL = URL(string: base) {
                await runEndToEnd(payload: payload, sessionURL: sessionURL,
                                  baseURL: baseURL)
            }
        } catch {
            check(false, "crypto contract", error.localizedDescription)
        }

        await recoveryChecks(payload: payload)
        if failed { exit(1) }
    }

    private static func recoveryChecks(payload: SharedNotePayload) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("links.json")
        let a = SharedLinksStore(storageURL: file), b = SharedLinksStore(storageURL: file)
        let meeting = dir.appendingPathComponent("deleted-meeting.md")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoints = WebShareConfiguration(apiBaseURL: URL(string: "https://test.invalid/api/shared-notes")!,
                                              viewerBaseURL: URL(string: "https://test.invalid/p")!)
        let service = WebShareService(configuration: endpoints, store: a, session: session)
        do {
            _ = try await a.allRecords(); _ = try await b.allRecords()
            func record(_ id: String) -> SharedLinkRecord {
                SharedLinkRecord(shareID: id, sessionPath: meeting.path, privateURL: "https://test.invalid/p/" + id + "#key",
                                 revokeToken: "token", createdAt: Date(), expiresAt: Date().addingTimeInterval(3600))
            }
            try await a.save(record("A")); try await b.save(record("B"))
            check(try await a.allRecords().count == 2, "independent stores preserve both links for the same meeting")
            try await b.remove(record("A"))
            check(try await a.allRecords().map(\.shareID) == ["B"], "stale store observes another writer's removal")
            check(try await a.allRecords().count == 1, "controls remain available without a transcript")
            SharingProtocol.handler = { request in
                let disk = try JSONDecoder().decode([SharedLinkRecord].self, from: Data(contentsOf: file))
                guard disk.contains(where: { $0.pending == true }) else { throw CocoaError(.fileReadUnknown) }
                throw URLError(.timedOut)
            }
            do { _ = try await service.create(payload: payload, sessionURL: meeting); check(false, "timeout surfaces") }
            catch { check((error as? URLError)?.code == .timedOut, "upload starts only after pending recovery is durable") }
            let restored = SharedLinksStore(storageURL: file)
            let pending = try await restored.allRecords().filter { $0.pending == true }
            check(pending.count == 1 && !pending[0].revokeToken.isEmpty, "timeout preserves recovery across relaunch")
            check(try await restored.allRecords(now: Date.distantFuture).contains { $0.pending == true },
                  "uncertain uploads retain controls until explicitly resolved")
            SharingProtocol.handler = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                return (201, try JSONSerialization.data(withJSONObject: ["id": body["id"]!, "expiresAt": Int(Date().timeIntervalSince1970) + 2592000]))
            }
            let success = try await service.create(payload: payload, sessionURL: meeting)
            let savedRecords = try await a.allRecords()
            check(success.pending == false && savedRecords.contains(success), "successful upload durably confirms the pending record")
            SharingProtocol.handler = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                // Simulate a local storage failure after the server has accepted upload.
                try FileManager.default.removeItem(atPath: file.path + ".lock")
                try FileManager.default.createDirectory(atPath: file.path + ".lock", withIntermediateDirectories: false)
                return (201, try JSONSerialization.data(withJSONObject: ["id": body["id"]!, "expiresAt": Int(Date().timeIntervalSince1970) + 2592000]))
            }
            do { _ = try await service.create(payload: payload, sessionURL: meeting); check(false, "confirmation write failure surfaces") }
            catch { check(true, "confirmation write failure surfaces") }
            try FileManager.default.removeItem(atPath: file.path + ".lock")
            check(try await a.allRecords().filter { $0.pending == true }.count == 2,
                  "server success plus local write failure retains pending capability")
            let concurrentFile = dir.appendingPathComponent("concurrent.json")
            let children = ["one", "two"].map { name -> Process in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = ["--writer", concurrentFile.path, name]
                return process
            }
            for child in children { try child.run() }
            for child in children { child.waitUntilExit() }
            let concurrentRecords = try await SharedLinksStore(storageURL: concurrentFile).allRecords()
            check(children.allSatisfy { $0.terminationStatus == 0 } && concurrentRecords.count == 40,
                  "concurrent processes preserve all forty ownership records")
            try "corrupt".write(to: file, atomically: true, encoding: .utf8)
            SharingProtocol.handler = { _ in throw URLError(.badURL) }
            do { _ = try await service.create(payload: payload, sessionURL: meeting); check(false, "storage failure blocks upload") }
            catch { check(!(error is URLError), "storage failure blocks upload before any request") }
        } catch { check(false, "recovery fixture", error.localizedDescription) }
    }

    private static func runEndToEnd(payload: SharedNotePayload,
                                    sessionURL: URL,
                                    baseURL: URL) async {
        struct Envelope: Decodable {
            let schemaVersion: Int
            let nonce: String
            let ciphertext: String
        }

        let config = WebShareConfiguration(
            apiBaseURL: baseURL.appendingPathComponent("api/shared-notes"),
            viewerBaseURL: baseURL.appendingPathComponent("p")
        )
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let service = WebShareService(configuration: config, store: SharedLinksStore(storageURL: fixture.appendingPathComponent("links.json")))
        do {
            let record = try await service.create(payload: payload, sessionURL: sessionURL)
            check(record.expiresAt.timeIntervalSince(record.createdAt) > 29 * 86_400,
                  "Worker assigns fixed 30-day expiry")
            guard let key = URLComponents(string: record.privateURL)?.fragment else {
                check(false, "private URL carries fragment key"); return
            }
            check(!record.privateURL.contains("?key="),
                  "private key is a fragment, never a query parameter")

            let apiURL = config.apiBaseURL.appendingPathComponent(record.shareID)
            let (data, response) = try await URLSession.shared.data(from: apiURL)
            check((response as? HTTPURLResponse)?.statusCode == 200,
                  "Worker reads encrypted record")
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            check(envelope.schemaVersion == 1, "Worker preserves schema version")
            let opened = try WebShareCrypto.decrypt(
                nonce: envelope.nonce, ciphertext: envelope.ciphertext,
                key: key, id: record.shareID
            )
            check(opened == payload, "Swift-created note survives Worker round trip")

            let (pageData, pageResponse) = try await URLSession.shared.data(
                from: config.viewerBaseURL.appendingPathComponent(record.shareID)
            )
            let page = String(data: pageData, encoding: .utf8) ?? ""
            check((pageResponse as? HTTPURLResponse)?.statusCode == 200
                  && page.contains("Opening private notes"),
                  "recipient viewer is served")

            try await service.revoke(record)
            do {
                let (_, goneResponse) = try await URLSession.shared.data(from: apiURL)
                check((goneResponse as? HTTPURLResponse)?.statusCode == 404,
                      "revocation removes ciphertext immediately")
            } catch {
                check(false, "revocation removes ciphertext immediately", error.localizedDescription)
            }
        } catch {
            check(false, "local Worker end to end", error.localizedDescription)
        }
    }
}


private final class SharingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                req.httpBody = data
            }
            let (status, data) = try Self.handler!(req)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                                 httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
