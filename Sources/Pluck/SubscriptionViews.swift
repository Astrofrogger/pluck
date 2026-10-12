import AppKit
import SwiftUI

/// A subscription at the top of its Library page: when Pluck last looked, what it saves as, and
/// checking now, pausing or unsubscribing.
struct SubscriptionCard: View {
    let subscription: Subscription
    /// Called after unsubscribing, to leave its page.
    let onRemove: () -> Void
    @State private var subscriptions = Subscriptions.shared
    @State private var confirmRemove = false

    private var isChecking: Bool { subscriptions.checking.contains(subscription.id) }

    var body: some View {
        Card {
            CardHeader(symbol: subscription.paused ? "pause.circle" : "dot.radiowaves.up.forward",
                       title: Text(subscription.title), subtitle: Text(detail),
                       tint: subscription.paused ? .secondary : .accentColor) {
                if isChecking {
                    StatusChip(text: Text("Looking…"), colour: .accentColor, busy: true)
                } else if subscription.paused {
                    StatusChip(text: Text("Paused"), colour: .secondary)
                } else {
                    StatusChip(text: Text("On"))
                }
            }
            if let problem = subscription.problem { ProblemLabel(text: problem) }
            HStack(spacing: Design.Spacing.controls) {
                BarPicker(symbol: subscription.options.isAudio ? "waveform" : "film", label: Text("Save as"),
                          selection: kind, current: Text(subscription.options.isAudio ? "Audio" : "Video")) {
                    Text("Video").tag(MediaKind.video)
                    Text("Audio").tag(MediaKind.audio)
                }
                Button("Check Now", systemImage: "arrow.clockwise") { subscriptions.check([subscription.id]) }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .disabled(isChecking || subscription.paused)
                Button(subscription.paused ? "Resume" : "Pause", systemImage: subscription.paused ? "play.fill" : "pause.fill") {
                    subscriptions.setPaused(!subscription.paused, for: subscription.id)
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                Spacer(minLength: 0)
                RowButton(symbol: "folder", label: "Show in Finder") { showFolder() }
                RowButton(symbol: "trash", label: "Unsubscribe") { confirmRemove = true }
            }
        }
        .confirmationDialog("Unsubscribe from “\(subscription.title)”?", isPresented: $confirmRemove) {
            Button("Unsubscribe", role: .destructive) {
                subscriptions.remove(subscription.id)
                onRemove()
            }
        } message: {
            Text("What it already downloaded stays where it is.")
        }
    }

    private var kind: Binding<MediaKind> {
        Binding {
            subscription.options.kind
        } set: { kind in
            var options = subscription.options
            options.kind = kind
            subscriptions.setOptions(options, for: subscription.id)
        }
    }

    /// "Checked 5 minutes ago · Saves to Downloads/Channel".
    private var detail: String {
        let checked = subscription.lastChecked.map {
            String(localized: "Checked \($0.formatted(.relative(presentation: .named)))")
        } ?? String(localized: "Not checked yet")
        let folder = URL(fileURLWithPath: subscription.folder)
        return checked + " · " + String(localized: "Saves to \(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)")
    }

    private func showFolder() {
        let folder = URL(fileURLWithPath: subscription.folder)
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([folder.deletingLastPathComponent()])
        }
    }
}

/// Subscribe from the Library: a channel, playlist or podcast link, then the usual picker in the
/// main window (with "Download new uploads automatically" on).
struct SubscribeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "dot.radiowaves.up.forward", title: Text("Subscribe"),
                        subtitle: Text("Pluck looks for new uploads every hour while it’s open and downloads them."),
                        subtitleIsName: false)
            InputBar(symbol: "link", prompt: Text("A YouTube channel, a playlist or a podcast feed"), text: $link, onSubmit: next) {
                EmptyView()
            }
            if let problem { ProblemLabel(text: problem) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: next)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
    }

    private func next() {
        guard let valid = Links.validated(link) else {
            problem = String(localized: "That doesn’t look like a link.")
            return
        }
        guard Playlists.looksLikePlaylist(valid), MusicLinks.parse(valid) == nil else {
            problem = String(localized: "That’s a single video. Paste a channel, a playlist or a podcast feed.")
            return
        }
        guard let manager = Subscriptions.shared.manager else { return }
        manager.add([valid])
        dismiss()
    }
}
