import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Edit Anywhere's Review pane: a finished render's preview streamed from the host, its timecoded
/// comments (from this Mac and from phones), click a time to jump there, and a marker file for Resolve.
struct RemoteReviewPane: View {
    @State private var client = OfficeRenderClient.shared
    @State private var chosen: String?

    private var renders: [OfficeRenderClient.Job] { client.jobs.filter { $0.previewSize != nil } }

    var body: some View {
        if renders.isEmpty {
            StudioEmptyState(symbol: "text.bubble", title: "Nothing to review yet", line: "Finished renders with a preview show up here.")
                .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review").font(Design.Studio.sectionTitle)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(renders) { job in
                            Button { chosen = job.id } label: {
                                Text(job.timeline).font(Design.Studio.body).lineLimit(1)
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(job.id == current?.id ? Design.Studio.raised : .clear, in: .capsule)
                                    .overlay(Capsule().strokeBorder(Design.Studio.line))
                                    .contentShape(.capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(job.id == current?.id ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.never)
                if let current { RemoteReviewDetail(job: current).id(current.id) }
            }
        }
    }

    private var current: OfficeRenderClient.Job? { renders.first { $0.id == chosen } ?? renders.first }
}

private struct RemoteReviewDetail: View {
    let job: OfficeRenderClient.Job
    @State private var client = OfficeRenderClient.shared
    @State private var stream: RemoteStream?
    @State private var player: AVPlayer?
    @State private var comments: [ReviewComment] = []
    @State private var problem: String?
    @State private var draft = ""
    @State private var replying: UUID?
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.black
                if let player { RemotePlayerSurface(player: player) } else { ProgressView().controlSize(.small) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))

            HStack(spacing: 8) {
                TextField("Comment at this moment", text: $draft)
                    .textFieldStyle(.plain).font(Design.Studio.body)
                    .padding(.horizontal, 12).frame(height: 32)
                    .studioBox(outline: Design.Studio.line)
                    .onSubmit(addComment)
                Button("Add", action: addComment)
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Markers for Resolve…", action: exportMarkers)
                    .buttonStyle(StudioFlatButtonStyle(height: 32))
                    .disabled(comments.isEmpty)
                    .help("A marker file to import in DaVinci Resolve: Timeline › Import › Timeline Markers from EDL")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
            }
            ForEach(comments) { comment in row(comment) }
        }
        .task {
            let stream = RemoteStream.preview(job)
            self.stream = stream
            player = AVPlayer(playerItem: AVPlayerItem(asset: stream.asset()))
        }
        .task {
            // Phones comment too: look again now and then while the pane is open.
            while !Task.isCancelled {
                await run { try await client.reviewComments(job) }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onDisappear { player?.pause() }
    }

    private func row(_ comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(ReviewComment.clock(comment.time)) { seek(comment.time) }
                    .buttonStyle(StudioFlatButtonStyle(height: 22))
                    .font(Design.Studio.hint.monospacedDigit())
                    .help("Jump to this moment")
                Text(comment.author).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                Spacer(minLength: 0)
                Button(comment.resolved ? LocalizedStringKey("Reopen") : LocalizedStringKey("Resolve")) {
                    Task { await run { try await client.resolveComment(job, comment.id, resolved: !comment.resolved) } }
                }
                .buttonStyle(StudioFlatButtonStyle(height: 22))
                Button { replying = replying == comment.id ? nil : comment.id } label: {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                .accessibilityLabel("Reply")
            }
            Text(comment.text).font(Design.Studio.body).textSelection(.enabled)
            ForEach(comment.replies) { answer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(answer.author).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    Text(answer.text).font(Design.Studio.body).textSelection(.enabled)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Design.Studio.line).frame(width: 2) }
            }
            if replying == comment.id {
                TextField("Reply", text: $reply)
                    .textFieldStyle(.plain).font(Design.Studio.body)
                    .padding(.horizontal, 10).frame(height: 28)
                    .studioBox(outline: Design.Studio.line)
                    .onSubmit { sendReply(comment.id) }
            }
        }
        .padding(10)
        .studioBox()
        .opacity(comment.resolved ? 0.55 : 1)
    }

    private func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func addComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let time = player?.currentTime().seconds ?? 0
        draft = ""
        Task { await run { try await client.addComment(job, time: time.isFinite ? time : 0, text: text) } }
    }

    private func sendReply(_ id: UUID) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        replying = nil
        Task { await run { try await client.addComment(job, time: 0, text: text, reply: id) } }
    }

    private func run(_ work: () async throws -> [ReviewComment]) async {
        do {
            comments = try await work()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func exportMarkers() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Folders.sanitize(job.timeline) + " markers.edl"
        panel.allowedContentTypes = [UTType(filenameExtension: "edl") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = comments, title = job.timeline, asset = player?.currentItem?.asset
        Task {
            let fps = (try? await asset?.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)).map(Double.init) ?? 25
            do {
                try RemoteReview.markerEDL(snapshot, title: title, fps: fps > 0 ? fps : 25).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
