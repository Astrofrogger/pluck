import SwiftUI

/// The Library split in two, as a file manager does: which side the sidebar chooses for, the
/// folder each side shows, and copying from one to the other (checked like an offload).
@MainActor
@Observable
final class LibraryPanes {
    static let shared = LibraryPanes()

    var split = UserDefaults.standard.bool(forKey: "librarySplit") {
        didSet { UserDefaults.standard.set(split, forKey: "librarySplit"); if !split { active = 0 } }
    }
    /// The side the sidebar chooses for (0 left, 1 right).
    var active = 0
    /// The folder open on each side.
    var here: [Int: URL] = [:]
    /// Why a copy couldn't start.
    var problem: String?

    /// The folder on the other side, when there's one.
    func other(_ pane: Int) -> URL? { split ? here[1 - pane] : nil }

    /// `move`: moved instead (to another drive: once every file's checked there).
    func copy(_ items: [URL], into folder: URL, move: Bool = false) {
        transfer(items, into: folder, moveHere: move, moveAcross: move)
    }

    /// A drop, as in Finder: on the same drive it moves (⌥ held copies); to another drive (a
    /// card, a disk) it's a checked copy (⌘ held moves).
    func drop(_ items: [URL], into folder: URL) {
        let flags = NSEvent.modifierFlags
        transfer(items, into: folder, moveHere: !flags.contains(.option), moveAcross: flags.contains(.command) && !flags.contains(.option))
    }

    /// Names already there are asked about first (Keep Both, Replace, Skip). Moves on the same
    /// drive happen at once (one undo); the rest is a checked copy (its undo once it's done).
    private func transfer(_ items: [URL], into folder: URL, moveHere: Bool, moveAcross: Bool) {
        let files = items.filter(\.isFileURL)
        let local = moveHere ? files.filter { FinderFiles.sameVolume($0, folder) } : []
        // (Not a folder into itself: weeded out before Replace sends anything to the Trash.)
        let rest = files.filter { !local.contains($0) && !FinderPane.isInside(folder, $0) }
        var notes: [String] = []
        if !local.isEmpty {
            FileUndo.shared.grouped(String(localized: "Move")) {
                let plan = FileClash.plan(local, into: folder)
                notes += plan.notes
                if !plan.items.isEmpty, let failed = FinderFiles.move(plan.items, into: folder, names: plan.names) { notes.append(failed) }
            }
        }
        if !rest.isEmpty {
            let plan = FileClash.plan(rest, into: folder, deferred: true)
            notes += plan.notes
            if !plan.items.isEmpty {
                let keys = plan.items.map { folder.appendingPathComponent(plan.names[$0] ?? $0.lastPathComponent).standardizedFileURL.path }
                Task {
                    let failed = await OffloadCenter.shared.copy(plan.items, into: folder, move: moveAcross, names: plan.names)
                    FileUndo.shared.copyStarted(keys)
                    if let failed { problem = (notes + [failed]).joined(separator: "\n") }
                }
            }
        }
        if !notes.isEmpty { problem = notes.joined(separator: "\n") }
    }
}

/// The Library's copies under way, at its foot: how far each is, and pausing or carrying on.
/// The rest (what went wrong, every copy so far) is in Offload.
struct LibraryTransfers: View {
    @State private var center = OffloadCenter.shared

    /// (A copy over in under a second isn't worth a bar.)
    private func shown(at now: Date) -> [OffloadJob] {
        center.jobs.filter { $0.quick == true && $0.finished == nil && now.timeIntervalSince($0.started) > 1 }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let jobs = shown(at: context.date)
            if !jobs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(jobs) { job in row(job) }
                }
                .padding(.horizontal, Design.Spacing.window)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// "3 of 12 files · 2 min left".
    private func progress(_ job: OffloadJob, _ live: OffloadCenter.Live?) -> String {
        let done = job.files.filter { !$0.done.contains(false) }.count
        var text = String(localized: "\(done) of \(job.files.count) files")
        if let live, live.speed > 0 {
            let left = Double(max(job.work - live.bytes, 0)) / live.speed
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = left >= 3600 ? [.hour, .minute] : left >= 60 ? [.minute] : [.second]
            if let time = formatter.string(from: max(left, 1)) { text += " · " + String(localized: "\(time) left") }
        }
        return text
    }

    private func row(_ job: OffloadJob) -> some View {
        let state = center.state(job)
        let live = center.live[job.id]
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
            Text("\(job.displayName) → \(URL(fileURLWithPath: job.roots[0]).lastPathComponent)")
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            StudioProgress(share: Double(live?.bytes ?? job.workDone) / Double(max(job.work, 1)))
            Text(progress(job, live))
                .font(Design.Studio.hint.monospacedDigit())
                .foregroundStyle(Design.Studio.textQuiet)
                .lineLimit(1)
                .fixedSize()
            Group {
                switch state {
                case .copying:
                    if let live, live.speed > 0 { Text("\(ByteCountFormatter.string(fromByteCount: Int64(live.speed), countStyle: .file))/s") }
                    else { Text(live?.checking == true ? "Checking…" : "Copying…") }
                case .queued: Text("Waiting")
                case .waiting(let drive): Text("Waiting for \(drive)")
                case .stopped(let problem): Text(problem).foregroundStyle(.red)
                default: Text("Paused")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 130, alignment: .trailing)
            if state == .copying || state == .queued {
                RowButton(symbol: "pause.fill", label: "Pause") { center.pause(job.id) }
            } else {
                RowButton(symbol: "play.fill", label: "Carry On") { center.resume(job.id) }
            }
            // (What's half-copied goes; what's copied whole stays, and a move's originals stay.)
            RowButton(symbol: "xmark", label: "Cancel") { center.cancel(job.id) }
        }
        .font(.callout)
        .contextMenu { Button("Show in Offload") { StudioNavigator.shared.open(.offload) } }
    }
}
