import AppKit
import SwiftUI

/// One deliberate checkpoint before any meeting text leaves the Mac.
/// V1 is intentionally fixed: curated notes only, immutable, 30-day expiry.
struct ShareNotesSheet: View {
    let sessionURL: URL
    let title: String
    let meetingDate: Date
    let durationMinutes: Int
    let payload: SharedNotePayload
    let onShared: (SharedLinkRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var createdRecord: SharedLinkRecord?
    @State private var copyConfirmed = false

    var body: some View {
        Group {
            if let createdRecord {
                successView(createdRecord)
            } else {
                creationView
            }
        }
        .frame(width: 580, height: createdRecord == nil ? 680 : 410)
        .background(Dorado.surface)
        .interactiveDismissDisabled(creating && createdRecord == nil)
        .animation(.easeInOut(duration: 0.2), value: createdRecord?.shareID)
    }

    private var creationView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Share meeting notes")
                        .font(Dorado.barlowXBold(26))
                        .foregroundStyle(Dorado.midnight)
                    Text("Creates an encrypted link on rhinovoice.app, hosted by Cloudflare. It expires in 30 days and is copied for you to send.")
                        .font(Dorado.roboto(13))
                        .foregroundStyle(Dorado.grey600)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Dorado.grey500)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .disabled(creating)
            }
            .padding(.init(top: 26, leading: 28, bottom: 20, trailing: 22))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(payload.title.isEmpty ? "Meeting notes" : payload.title)
                            .font(Dorado.barlowBold(19))
                            .foregroundStyle(Dorado.midnight)
                        Text(metaLine)
                            .font(Dorado.roboto(12))
                            .foregroundStyle(Dorado.grey500)
                    }

                    if !payload.summary.isEmpty {
                        previewSection("Summary") {
                            Text(payload.summary)
                                .font(Dorado.roboto(14))
                                .foregroundStyle(Dorado.grey800)
                                .lineSpacing(4)
                        }
                    }

                    ForEach(Array(payload.sections.enumerated()), id: \.offset) { _, section in
                        previewSection(section.heading) {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                                    bulletRow(bullet)
                                }
                            }
                        }
                    }

                    if !payload.nextSteps.isEmpty {
                        previewSection("Next steps") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(payload.nextSteps.enumerated()), id: \.offset) { _, action in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: action.isDone ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(action.isDone ? Color.green : Dorado.grey500)
                                        Text(action.text)
                                            .font(Dorado.roboto(14))
                                            .foregroundStyle(Dorado.grey800)
                                            .strikethrough(action.isDone)
                                    }
                                }
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Dorado.dollar)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("The transcript stays on this Mac")
                                .font(Dorado.barlowBold(13))
                                .foregroundStyle(Dorado.midnight)
                            Text("Raw transcript, coaching nudges, wins, focus suggestions, and talk-time statistics are not included. Anyone with the complete link can read this snapshot.")
                                .font(Dorado.roboto(12))
                                .foregroundStyle(Dorado.grey600)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Dorado.surfaceSubtle)
                    )
                }
                .padding(28)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(Dorado.roboto(12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DoradoOutlineButtonStyle())
                        .disabled(creating)
                    Spacer()
                    Button {
                        createShare()
                    } label: {
                        HStack(spacing: 8) {
                            if creating { ProgressView().controlSize(.small) }
                            Image(systemName: "link")
                            Text(creating ? "Creating private link…" : "Create private link")
                        }
                    }
                    .buttonStyle(DoradoOutlineButtonStyle())
                    .disabled(creating)
                }
            }
            .padding(.init(top: 16, leading: 28, bottom: 22, trailing: 28))
        }
    }

    private func successView(_ record: SharedLinkRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Private link ready")
                        .font(Dorado.barlowXBold(26))
                        .foregroundStyle(Dorado.midnight)
                    Text("Send the next steps while the conversation is fresh. Recipients can read them without an account.")
                        .font(Dorado.roboto(13))
                        .foregroundStyle(Dorado.grey600)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Dorado.grey500)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Done")
            }
            .padding(.init(top: 26, leading: 28, bottom: 20, trailing: 22))

            Divider()

            VStack(spacing: 16) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Dorado.dollar)
                Text(copyConfirmed ? "Link copied" : "Ready to share")
                    .font(Dorado.barlowBold(20))
                    .foregroundStyle(Dorado.midnight)
                Text("Only the summary, topic notes, and next steps are included. Anyone with the complete link can read them until \(expiryText(record.expiresAt)).")
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey600)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)

                HStack(spacing: 10) {
                    Button {
                        copyPrivateLink(record)
                    } label: {
                        Label(copyConfirmed ? "Copied" : "Copy link",
                              systemImage: copyConfirmed ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(DoradoOutlineButtonStyle())

                    if let url = record.url {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open", systemImage: "safari")
                        }
                        .buttonStyle(DoradoOutlineButtonStyle())

                        ShareLink(
                            item: url,
                            subject: Text(payload.title.isEmpty ? "Meeting notes" : payload.title),
                            message: Text("Here are the meeting notes and next steps.")
                        ) {
                            Label("Send notes…", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Dorado.dollar)
                        .controlSize(.large)
                        .help("Send with Messages, Mail, AirDrop, or another app")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(DoradoOutlineButtonStyle())
            }
            .padding(.init(top: 16, leading: 28, bottom: 22, trailing: 28))
        }
    }

    private var metaLine: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var parts = [formatter.string(from: meetingDate)]
        if durationMinutes > 0 { parts.append("\(durationMinutes) min") }
        return parts.joined(separator: " · ")
    }

    private func previewSection<Content: View>(_ title: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(Dorado.barlowBold(14))
                .foregroundStyle(Dorado.midnight)
            content()
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Dorado.grey400).frame(width: 4, height: 4)
            Text(text)
                .font(Dorado.roboto(14))
                .foregroundStyle(Dorado.grey800)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func copyPrivateLink(_ record: SharedLinkRecord) {
        guard let url = record.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copyConfirmed = true
    }

    private func createShare() {
        creating = true
        errorMessage = nil
        Task {
            do {
                let service = WebShareService()
                let record = try await service.create(
                    payload: payload, sessionURL: sessionURL
                )
                copyPrivateLink(record)
                onShared(record)
                createdRecord = record
            } catch {
                errorMessage = "Couldn’t finish creating the link. Any pending upload is kept in Shared links so you can stop sharing. " + error.localizedDescription
                creating = false
            }
        }
    }
}

/// Lives outside individual meetings, so deleting a transcript never hides ownership.
struct SharedLinksManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [SharedLinkRecord] = []
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var selected: SharedLinkRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Shared links").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
            }
            Text("Manage shared notes even after deleting their meeting. Pending uploads keep their recovery controls here until you stop sharing.")
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if records.isEmpty { Text("No shared links").foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.title ?? TranscriptSearch.displayTitle(for: URL(fileURLWithPath: record.sessionPath)))
                                .font(.headline)
                            Text(record.pending == true ? "Pending upload — stop sharing to cancel safely" : "Expires \(record.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if record.pending != true, let url = record.url {
                                    ShareLink("Send notes", item: url)
                                    Button("Copy link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                }
                                Spacer()
                                Button("Stop sharing", role: .destructive) { selected = record }
                            }.disabled(busy)
                        }.padding(14).background(Dorado.surfaceSubtle, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            Button("Refresh") { Task { await reload() } }.disabled(busy)
        }
        .padding(24).frame(width: 560, height: 500).background(Dorado.surface)
        .interactiveDismissDisabled(busy)
        .task { await reload() }
        .confirmationDialog("Stop sharing these notes?", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible) {
            if let record = selected {
                Button("Stop sharing", role: .destructive) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await WebShareService().revoke(record)
                            try await SharedLinksStore.shared.remove(record)
                            await reload()
                        } catch { errorMessage = "Couldn’t stop sharing. The controls are saved; retry when online. " + error.localizedDescription }
                    }
                }
            }
        }
    }

    private func reload() async {
        do {
            records = try await SharedLinksStore.shared.allRecords()
            errorMessage = nil
        } catch { errorMessage = "Couldn’t read shared links: " + error.localizedDescription }
    }
}
