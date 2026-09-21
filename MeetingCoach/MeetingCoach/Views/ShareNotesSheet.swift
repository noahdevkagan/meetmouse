import AppKit
import SwiftUI

/// Opened by the explicit Share notes action; prepares and copies the link immediately.
/// V1 is intentionally fixed: curated notes only, immutable, 30-day expiry.
struct ShareNotesSheet: View {
    let sessionURL: URL
    let payload: SharedNotePayload
    let onShared: (SharedLinkRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var started = false
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
        .frame(width: 580, height: 410)
        .background(Dorado.surface)
        .interactiveDismissDisabled(creating && createdRecord == nil)
        .animation(.easeInOut(duration: 0.2), value: createdRecord?.shareID)
        .onAppear {
            guard !started else { return }
            started = true
            createShare()
        }
    }

    private var creationView: some View {
        VStack(spacing: 20) {
            if let errorMessage {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(Dorado.grey600)
                Text("Couldn’t create private link")
                    .font(Dorado.barlowXBold(26))
                    .foregroundStyle(Dorado.midnight)
                Text(errorMessage)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey600)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Done") { dismiss() }
                        .buttonStyle(DoradoOutlineButtonStyle())
                    Button("Try again") { createShare() }
                        .buttonStyle(.borderedProminent)
                        .tint(Dorado.dollar)
                }
            } else {
                ProgressView()
                Text("Creating private link…")
                    .font(Dorado.barlowXBold(26))
                    .foregroundStyle(Dorado.midnight)
                Text("Encrypting your summary, topic notes, and next steps. The link will be copied when it’s ready.")
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey600)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        guard !creating else { return }
        creating = true
        errorMessage = nil
        Task {
            defer { creating = false }
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
