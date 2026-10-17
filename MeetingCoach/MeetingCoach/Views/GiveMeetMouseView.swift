import SwiftUI
import AppKit

/// "Get MeetMouse Unlimited": invite 2 friends, buy once for $20, or enter
/// a code. Free users reach it from the sidebar card, the menu bar, and the
/// limit sheet when a 4th meeting in a week is refused (`limitReached`).
/// Unlocked users only see the share half ("Share MeetMouse with friends").
/// Opening links hands them to the browser; the app never calls the site.
struct GiveMeetMouseView: View {
    /// Sheet mode: the weekly limit was just hit, so lead with that.
    var limitReached = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private var tier = FreeTier.shared
    @State private var copied = false
    @State private var code = ""
    @State private var codeRejected = false

    init(limitReached: Bool = false) {
        self.limitReached = limitReached
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if tier.isUnlocked {
                if limitReached {
                    Label("Unlocked. Start your meeting again.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                shareBox
            } else {
                inviteSection
                Divider()
                buySection
                codeSection
            }

            HStack {
                Spacer()
                Button(limitReached ? "Not now" : "Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tier.isUnlocked ? "Share MeetMouse with friends"
                 : limitReached ? "You've used your 3 free meetings this week"
                 : "Get MeetMouse Unlimited")
                .font(.title3.bold())
            Text(tier.isUnlocked
                 ? "Send your link to anyone who lives in meetings. MeetMouse is free for them."
                 : limitReached
                 ? "Your notes and transcripts stay open. To record more meetings this week, unlock MeetMouse for good:"
                 : statusLine)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        if tier.isInTrial {
            let d = tier.trialDaysLeft
            return "Unlimited meetings for \(d) more \(d == 1 ? "day" : "days"), then \(UsageGate.weeklyFreeMeetings) a week. Notes are never locked."
        }
        let left = tier.meetingsLeftThisWeek
        return "\(left) of \(UsageGate.weeklyFreeMeetings) free meetings left this week (resets Monday). Notes are never locked."
    }

    @ViewBuilder private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite \(ReferralLink.friendsNeeded) friends, get Unlimited free")
                .font(.headline)
            Text("When \(ReferralLink.friendsNeeded) friends get MeetMouse through your link, your status page gives you the unlock.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            shareBox
            Button("Check my invites") { openURL(tier.referral.statusURL) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    @ViewBuilder private var shareBox: some View {
        let referral = tier.referral
        VStack(alignment: .leading, spacing: 8) {
            Text(referral.inviteMessage)
                .font(.caption)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(cornerRadius: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(referral.inviteMessage, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied. Paste it anywhere" : "Copy invite",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var buySection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Or buy it once").font(.headline)
                Text("$20, no subscription. Also unlocks with an AppSumo code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Buy — $20") { openURL(URL(string: "https://meetmouse.com/#buy")!) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var codeSection: some View {
        HStack {
            TextField("Have a code? MOUSE-… or AppSumo code", text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(redeem)
            Button("Unlock", action: redeem)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if codeRejected {
            Text("That code didn't work. Check for typos and try again.")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func redeem() {
        codeRejected = !tier.unlock(code: code)
    }
}

/// Sidebar card for free users: what's left, plus the way to Unlimited.
struct FreeTierCard: View {
    var onOpen: () -> Void
    private var tier = FreeTier.shared

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
    }

    var body: some View {
        if !tier.isUnlocked {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Get Unlimited free", systemImage: "gift")
                        .font(.system(size: 13, weight: .semibold))
                    Text(tier.isInTrial
                         ? "Unlimited for \(tier.trialDaysLeft) more \(tier.trialDaysLeft == 1 ? "day" : "days"). Invite \(ReferralLink.friendsNeeded) friends to keep it."
                         : "\(tier.meetingsLeftThisWeek) of \(UsageGate.weeklyFreeMeetings) meetings left this week. Invite \(ReferralLink.friendsNeeded) friends for Unlimited.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .cardStyle()
            }
            .buttonStyle(.plain)
        }
    }
}
