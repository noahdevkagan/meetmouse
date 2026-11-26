import CryptoKit
import Foundation

private var failed = false

private func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    print("team \(label): \(condition ? "PASS" : "FAIL\(detail.isEmpty ? "" : " — \(detail)")")")
    if !condition { failed = true }
}

@main
struct TeamTests {
    static func main() throws {
        // Vectors shared with web-share/test/teams.test.mjs: secret is 32
        // bytes of 0x07, nonce 12 bytes of 0x01.
        let secret = Data(repeating: 7, count: 32)
        let secretText = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
        let teamID = "TEAMabcdefghijklmnopqr"

        check(TeamCrypto.accessToken(secret: secret) == "-yp-K4zAAXg4RfCUqqpRMp9ER9x3QCfdNjam1w7Fk3U",
              "access token matches the Worker contract", TeamCrypto.accessToken(secret: secret))
        check(TeamCrypto.accessHash(secret: secret) == "fqWs97gOqPbzgIA_HYHnYwSL9EHYkGo4Cva4gE54hLQ",
              "access hash matches what the server stores")
        check(WebShareCrypto.base64URL(TeamCrypto.notesKey(secret: secret))
                == "8brxkuOho6mFxHyaxS-5Vd9CutsQyB3Ee4w9NHpOSrY",
              "notes key matches the team page's derivation")
        check(TeamCrypto.noteID(secret: secret, memberID: "member-1",
                                sessionFile: "session_2026-08-01_15-30.md") == "rWwKzE36mVM7MpHzZ6SS1A",
              "note id is stable per member and meeting")
        check(TeamCrypto.noteID(secret: secret, memberID: "member-2",
                                sessionFile: "session_2026-08-01_15-30.md") != "rWwKzE36mVM7MpHzZ6SS1A",
              "two members' notes for the same file name don't collide")

        let fixedNonce = try AES.GCM.Nonce(data: Data(repeating: 1, count: 12))
        let sealedName = try TeamCrypto.seal(TeamName(name: "Acme"), secret: secret,
                                             teamID: teamID, context: "name", nonce: fixedNonce)
        check(sealedName.nonce == "AQEBAQEBAQEBAQEB"
                && sealedName.ciphertext == "tPzi-TjBWOiGUtLxcUPY3TjSYqfkagT-HM2mQjxaDg",
              "sealed bytes match the JavaScript reference", sealedName.ciphertext)
        let opened = try TeamCrypto.unseal(TeamName.self, nonce: sealedName.nonce,
                                           ciphertext: sealedName.ciphertext, secret: secret,
                                           teamID: teamID, context: "name")
        check(opened.name == "Acme", "sealed team name opens")

        // A note: round trip, bound to its slot, and nothing private in it.
        var review = MeetingReview(
            title: "Private quarterly plan",
            summary: "The team chose the smaller launch.",
            sections: [ReviewSection(heading: "Launch scope", bullets: ["Ship referrals first."])],
            takeaways: ["Measure recipient opens."],
            actionItems: [ActionItem(text: "Recruit ten testers")],
            wins: ["PRIVATE-COACHING-WIN"],
            nextFocus: "PRIVATE-NEXT-FOCUS",
            talkShare: 0.72
        )
        review.actionItems[0].isDone = true
        guard let note = SharedNotePayload.make(title: "Growth planning",
                                                date: Date(timeIntervalSince1970: 1_789_430_400),
                                                durationMinutes: 42, review: review) else {
            check(false, "topic notes are eligible to share")
            exit(1)
        }
        let payload = TeamNotePayload(schemaVersion: 1, author: "Ana Lopez", note: note)
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        check(json.contains("\"author\":\"Ana Lopez\"") && json.contains("Launch scope"),
              "team note carries the author and the curated notes")
        check(!json.contains("PRIVATE-COACHING-WIN") && !json.contains("PRIVATE-NEXT-FOCUS")
                && !json.contains("talkShare") && !json.contains("transcript"),
              "coaching, transcript and talk stats cannot enter a team note", json)

        let noteID = "rWwKzE36mVM7MpHzZ6SS1A"
        let sealed = try TeamCrypto.seal(payload, secret: secret, teamID: teamID, context: noteID)
        check(!sealed.ciphertext.contains("Growth") && sealed.nonce != sealedName.nonce,
              "note is encrypted with a fresh nonce")
        let roundTrip = try TeamCrypto.unseal(TeamNotePayload.self, nonce: sealed.nonce,
                                              ciphertext: sealed.ciphertext, secret: secret,
                                              teamID: teamID, context: noteID)
        check(roundTrip == payload, "note round-trips")
        check((try? TeamCrypto.unseal(TeamNotePayload.self, nonce: sealed.nonce,
                                      ciphertext: sealed.ciphertext, secret: secret,
                                      teamID: teamID, context: "AAAAAAAAAAAAAAAAAAAAAA")) == nil,
              "a note can't be opened under another note's id")
        check((try? TeamCrypto.unseal(TeamNotePayload.self, nonce: sealed.nonce,
                                      ciphertext: sealed.ciphertext, secret: secret,
                                      teamID: "OTHERabcdefghijklmnopq", context: noteID)) == nil,
              "a note can't be moved to another team")
        check((try? TeamCrypto.unseal(TeamNotePayload.self, nonce: sealed.nonce,
                                      ciphertext: sealed.ciphertext,
                                      secret: Data(repeating: 9, count: 32),
                                      teamID: teamID, context: noteID)) == nil,
              "another team's secret can't open it")
        check((try? TeamCrypto.seal(payload, secret: Data(repeating: 7, count: 8),
                                    teamID: teamID, context: noteID)) == nil,
              "a short secret is refused")

        // Invite links.
        let page = TeamInvite.parse("  https://meetmouse.com/t/\(teamID)#\(secretText)\n")
        check(page == TeamInvite(teamID: teamID, secret: secretText), "team page link parses")
        check(TeamInvite.parse("meetmouse://team?id=\(teamID)&key=\(secretText)") == page,
              "app link from the team page parses to the same invite")
        check(TeamInvite.parse("https://meetmouse.com/t/\(teamID)") == nil,
              "a link without the secret is refused")
        check(TeamInvite.parse("https://meetmouse.com/t/\(teamID)#tooshort") == nil,
              "a truncated secret is refused")
        check(TeamInvite.parse("https://meetmouse.com/p/\(teamID)#\(secretText)") == nil,
              "a private note link is not a team invite")
        check(TeamInvite.parse("https://meetmouse.com/t/short#\(secretText)") == nil,
              "a malformed team id is refused")
        check(TeamInvite.parse("meetmouse://unlock?code=ABC") == nil
                && TeamInvite.parse("hello") == nil && TeamInvite.parse("") == nil,
              "other text is refused")

        // Membership on disk.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("team-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TeamStore(storageURL: dir.appendingPathComponent("team.json"))
        check(store.load() == nil, "no membership before joining")
        var membership = TeamMembership(teamID: teamID, secret: secretText, teamName: "Acme",
                                        memberName: "Ana Lopez", memberID: "member-1",
                                        apiBaseURL: "https://meetmouse.com/api/teams",
                                        pageBaseURL: "https://meetmouse.com/t")
        membership.shared["session_2026-08-01_15-30.md"] =
            membership.noteID(forSessionFile: "session_2026-08-01_15-30.md")
        try store.save(membership)
        check(store.load() == membership, "membership round-trips")
        check(membership.shared.values.first == noteID, "membership derives the contract note id")
        check(membership.inviteLink == "https://meetmouse.com/t/\(teamID)#\(secretText)"
                && TeamInvite.parse(membership.inviteLink) == page,
              "the invite link is the team page link")
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.storageURL.path))?[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "membership file is readable by the user only")
        // Default-on sharing: only meetings after joining, never ones the
        // member took down, and not once the member turns it off.
        let joined = Date(timeIntervalSince1970: 1_790_000_000)
        var auto = TeamMembership(teamID: teamID, secret: secretText, teamName: "Acme",
                                  memberName: "Ana Lopez", memberID: "member-1",
                                  apiBaseURL: "https://meetmouse.com/api/teams",
                                  pageBaseURL: "https://meetmouse.com/t", joinedAt: joined)
        let after = joined.addingTimeInterval(86_400)
        check(auto.sharesAutomatically, "team sharing is on by default")
        check(auto.shouldAutoShare(sessionFile: "new.md", sessionDate: after),
              "a meeting after joining is shared automatically")
        check(!auto.shouldAutoShare(sessionFile: "old.md", sessionDate: joined.addingTimeInterval(-7 * 86_400)),
              "a meeting from before joining is never shared automatically")
        check(!auto.shouldAutoShare(sessionFile: "undated.md", sessionDate: nil),
              "a meeting without a date is not shared automatically")
        auto.shared["new.md"] = "note"
        check(!auto.shouldAutoShare(sessionFile: "new.md", sessionDate: after),
              "a meeting already on the team page is not sent again")
        auto.shared["new.md"] = nil
        auto.excluded = ["new.md"]
        check(!auto.shouldAutoShare(sessionFile: "new.md", sessionDate: after),
              "a meeting the member took down is not put back")
        auto.excluded = nil
        auto.autoShare = false
        check(!auto.shouldAutoShare(sessionFile: "new.md", sessionDate: after),
              "opting out stops automatic sharing")
        check(!membership.shouldAutoShare(sessionFile: "new.md", sessionDate: after),
              "a membership with no join date shares nothing automatically")
        let legacy = Data(#"{"teamID":"TEAMabcdefghijklmnopqr","secret":"s","teamName":"Acme","memberName":"Ana","memberID":"m","shared":{},"apiBaseURL":"a","pageBaseURL":"p"}"#.utf8)
        check((try? JSONDecoder().decode(TeamMembership.self, from: legacy))?.sharesAutomatically == true,
              "a membership file without the new fields still loads")

        store.archive(membership)
        store.clear()
        check(store.load() == nil, "leaving takes this Mac off the team")
        check(store.archived(teamID: teamID, secret: secretText) == membership,
              "a team that was left can be restored with its shared list")
        check(store.archived(teamID: teamID, secret: "other") == nil,
              "a different secret does not restore it")
        var renamed = membership
        renamed.teamName = "Acme Growth"
        store.archive(renamed)
        check(store.archived().count == 1 && store.archived().first?.teamName == "Acme Growth",
              "archiving the same team again replaces its entry")

        exit(failed ? 1 : 0)
    }
}
