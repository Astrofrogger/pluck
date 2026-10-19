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

    func copy(_ items: [URL], into folder: URL) {
        Task {
            problem = await OffloadCenter.shared.copy(items.filter(\.isFileURL), into: folder)
        }
    }
}

/// The Library's copies under way, at its foot: how far each is, and pausing or carrying on.
/// The rest (what went wrong, every copy so far) is in Offload.
struct LibraryTransfers: View {
    @State private var center = OffloadCenter.shared

    private var shown: [OffloadJob] { center.jobs.filter { $0.quick == true && $0.finished == nil } }

    var body: some View {
        if !shown.isEmpty {
            VStack(spacing: 6) {
                ForEach(shown) { job in row(job) }
            }
            .padding(.horizontal, Design.Spacing.window)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func row(_ job: OffloadJob) -> some View {
        let state = center.state(job)
        let live = center.live[job.id]
        return HStack(spacing: 10) {
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
            Text("\(job.displayName) → \(URL(fileURLWithPath: job.roots[0]).lastPathComponent)")
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            ProgressView(value: Double(live?.bytes ?? job.workDone), total: Double(max(job.work, 1)))
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
                RowButton(symbol: "xmark", label: "Remove") { center.remove(job.id) }
            }
        }
        .font(.callout)
        .contextMenu { Button("Show in Offload") { StudioNavigator.shared.open(.offload) } }
    }
}
