import SwiftUI

/// The post-meeting notes card: Summary / Notes (topic subheads) / Next
/// steps, mirroring the shared web page, with personal coaching in a quiet
/// footer — renders the structured MeetingReview, so no literal markdown
/// ever reaches the user.
struct MeetingReviewView: View {
    let review: MeetingReview
    /// Full shareable recap (summary + session facts + footer). When set,
    /// copy/share controls appear in the card header.
    var recapText: String?
    var onToggleActionItem: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if !review.summary.isEmpty {
                section(icon: "text.alignleft", title: "Summary") {
                    Text(review.summary)
                        .font(Self.bodyFont)
                        .lineSpacing(Self.lineSpacing)
                        .foregroundStyle(Dorado.grey800)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Topic-grouped notes under one "Notes" heading, laid out like
            // the shared web page (one section, topic subheads) rather than
            // a chip + divider per topic. The flat Key Takeaways list only
            // renders for deterministic and pre-0.22 reviews.
            if !review.sections.isEmpty {
                Divider()
                section(icon: "number", title: "Notes") {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(review.sections.enumerated()), id: \.offset) { _, topic in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(topic.heading)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Dorado.midnight)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                bulletList(topic.bullets)
                            }
                        }
                    }
                }
            }

            if !review.takeaways.isEmpty {
                Divider()
                section(icon: "star.fill", title: "Key takeaways") {
                    bulletList(review.takeaways)
                }
            }

            if !review.actionItems.isEmpty {
                Divider()
                section(icon: "checkmark", title: "Next steps") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(review.actionItems) { item in
                            Button {
                                onToggleActionItem?(item.id)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 14))
                                        .foregroundStyle(item.isDone ? Dorado.dollar : Color.secondary)
                                    Text(item.text)
                                        .font(Self.bodyFont)
                                        .lineSpacing(Self.lineSpacing)
                                        .strikethrough(item.isDone)
                                        .foregroundStyle(item.isDone ? Color.secondary : Dorado.grey800)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if hasCoaching {
                coachingFooter
            }

            if review.isDeterministic {
                Text("Basic recap written on this Mac without AI. Connect Claude (or another AI) for full notes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private static let bodyFont = Font.system(size: 14)
    private static let lineSpacing: CGFloat = 4

    private var hasCoaching: Bool {
        review.talkShare != nil || !review.wins.isEmpty
            || !(review.nextFocus ?? "").isEmpty
    }

    /// Personal coaching sits below the notes, quieter — it is about you,
    /// not the meeting, and never goes into a shared link.
    private var coachingFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Just for you", systemImage: "lock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let share = review.talkShare {
                // Whole-meeting on purpose — the live nudges watch recent
                // windows; this answers "over the whole call".
                Text("Talk time: you \(Int(share * 100))% · them \(100 - Int(share * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(review.wins.enumerated()), id: \.offset) { _, win in
                Label {
                    Text(win).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.thumbsup").foregroundStyle(Dorado.dollar)
                }
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let focus = review.nextFocus, !focus.isEmpty {
                Label {
                    Text("Next meeting: \(focus)").fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "target").foregroundStyle(.orange)
                }
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.06)))
    }

    private var header: some View {
        HStack {
            Label("Meeting notes", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let recap = recapText {
                CopyButton(help: "Copy recap for Slack or email") { recap }
                ShareLink(item: recap) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Share recap")
            }
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Dorado.grey500)
                        .frame(width: 4, height: 4)
                        .offset(y: -3)
                    Text(item)
                        .font(Self.bodyFont)
                        .lineSpacing(Self.lineSpacing)
                        .foregroundStyle(Dorado.grey800)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One heading style for every section — the web page's green chip.
    private func section(icon: String, title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Dorado.dollar)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Dorado.dollar.opacity(0.12))
                    )
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Dorado.midnight)
            }
            content()
        }
    }
}
