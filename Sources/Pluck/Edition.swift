import SwiftUI

/// Which Pluck this is: Pluck Studio (downloads plus local AI, editing tools and Edit Anywhere)
/// or basic Pluck (downloads, the Library, sharing and converting). Both are built from the same
/// code; see Package.swift.
enum Edition {
    #if STUDIO
    static let isStudio = true
    #else
    static let isStudio = false
    #endif

    static var name: String { isStudio ? "Pluck Studio" : "Pluck" }

    /// The in-app updater's download for this edition. ("Pluck.zip" is Studio too: Pluck 1.15 and
    /// older look for that name, and they had everything.)
    static var updateAsset: String { isStudio ? "Pluck-Studio.zip" : "Pluck-Basic.zip" }
}

extension View {
    /// What Studio's windows share (its local-AI jobs); nothing in basic Pluck.
    @ViewBuilder
    func studio(_ app: AppDelegate) -> some View {
        #if STUDIO
        environment(app.ai)
        #else
        self
        #endif
    }
}

/// The one-time choice for people updating from before there were two editions: keep everything
/// (Pluck Studio) or switch to the focused basic Pluck. New people chose by what they downloaded.
enum EditionChoice {
    private static let chosenKey = "editionChosen"

    @MainActor static var isNeeded = false

    /// At launch, with WhatsNew's verdict: a fresh install has chosen already.
    @MainActor static func prepare(isUpdate: Bool) {
        let defaults = UserDefaults.standard
        if !isUpdate { defaults.set(true, forKey: chosenKey) }
        isNeeded = isUpdate && !defaults.bool(forKey: chosenKey)
    }

    @MainActor private static var window: NSWindow?

    /// Shows the choice; `then` runs once it's settled (and Pluck stays this edition).
    @MainActor static func showIfNeeded(updater: AppUpdater, then: @escaping () -> Void) {
        guard isNeeded, window == nil else { return then() }
        let view = EditionChoiceView(updater: updater) { switching in
            UserDefaults.standard.set(true, forKey: chosenKey)
            isNeeded = false
            if switching {
                // The other edition's notes don't apply here: it opens fresh after the switch.
                WhatsNew.markSeen()
            } else {
                window?.close()
                then()
            }
        }
        let hosting = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.styleMask = [.titled, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.title = String(localized: "Choose Your Pluck")
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct EditionChoiceView: View {
    let updater: AppUpdater
    /// true: switching to the other edition (Pluck relaunches); false: keeping this one.
    let done: (Bool) -> Void
    @State private var switching = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "square.split.2x1", title: Text("Pluck now comes in two versions"),
                        subtitle: Text("Pick the one that fits you. You can switch any time in Settings, and your downloads, Library and settings stay."),
                        subtitleIsName: false)
            HStack(alignment: .top, spacing: Design.Spacing.controls) {
                card(studio: false, title: "Pluck", symbol: "arrow.down.circle",
                     detail: "Downloading videos and music, the Library, sharing to your phone and converting files. Small and focused.")
                card(studio: true, title: "Pluck Studio", symbol: "sparkles",
                     detail: "Everything in Pluck, plus local AI (subtitles, summaries, shorts, stems…), the editing tools for DaVinci Resolve, the Logo Animator and Edit Anywhere.")
            }
            if case .failed(let message) = updater.status, switching {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if updater.status == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading the other version… Pluck reopens by itself.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 560)
    }

    private func card(studio: Bool, title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) -> some View {
        let current = studio == Edition.isStudio
        return VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                if current {
                    done(false)
                } else {
                    switching = true
                    Task {
                        await updater.switchEdition()
                        // Only back here if it failed (a switch quits and reopens Pluck).
                    }
                    done(true)
                }
            } label: {
                Text(current ? "Keep This One" : "Switch to This One").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(current ? .accentColor : .secondary)
            .disabled(updater.status == .installing)
        }
        .padding(Design.Spacing.inset)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Design.Radius.box))
    }
}
