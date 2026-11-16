import SwiftUI

/// Comments as markers on the timeline open in DaVinci Resolve (§13.5). Frames map by the timeline's rate over the
/// version's; sending again replaces Pluck's markers (by their `pluck:<id>` data) instead of piling up; a frame
/// that has a marker already moves on by up to 5 frames, else it's skipped and listed.
@MainActor
enum DeliverResolveMarkers {
    struct Marker: Equatable {
        var frame: Int, color: String, name: String, note: String, duration: Int, data: String
        var json: [String: Any] { ["frame": frame, "color": color, "name": name, "note": note, "duration": duration, "data": data] }
    }

    struct Result: Equatable { var timeline: String; var added: Int; var moved: [String]; var skipped: [String] }

    /// Resolve's side (tests stand in a fake bridge).
    static var bridge: ([String: Any]) async throws -> [String: Any] = { try await ResolveBridge.run($0) }

    /// Timeline frames per version frame.
    static func factor(rate: Double, probe: Deliver.Probe) -> Double { rate * Double(probe.fpsDen) / Double(max(probe.fpsNum, 1)) }

    static func markers(_ comments: [Deliver.Comment], probe: Deliver.Probe, rate: Double, openOnly: Bool, includeInternal: Bool) -> [Marker] {
        let factor = factor(rate: rate, probe: probe)
        return comments.compactMap { comment in
            guard let frame = comment.frame, comment.page == nil else { return nil }   // general comments and documents: none
            if openOnly, comment.completed { return nil }
            if !includeInternal, comment.isInternal { return nil }
            let at = Int((Double(frame) * factor).rounded())
            let duration = max(1, Int((Double((comment.endFrame ?? frame) - frame + 1) * factor).rounded()))
            let color = comment.completed ? "Green" : comment.isInternal ? "Purple" : "Red"
            let note = ([comment.text] + comment.replies.map { "— \($0.author): \($0.text)" }).joined(separator: "\n")
            return Marker(frame: at, color: color, name: "\(comment.author): \(comment.text.prefix(40))", note: note, duration: duration, data: "pluck:\(comment.id.uuidString)")
        }
    }

    /// Frames taken by other markers: the next free one within 5, else skipped.
    static func place(_ markers: [Marker], occupied: Set<Int>) -> (placed: [Marker], moved: [String], skipped: [String]) {
        var taken = occupied, placed: [Marker] = [], moved: [String] = [], skipped: [String] = []
        for var marker in markers.sorted(by: { $0.frame < $1.frame }) {
            guard let free = (0...5).map({ marker.frame + $0 }).first(where: { !taken.contains($0) }) else { skipped.append(marker.data); continue }
            if free != marker.frame { moved.append(marker.data) }
            marker.frame = free
            taken.insert(free)
            placed.append(marker)
        }
        return (placed, moved, skipped)
    }

    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }

    /// The open timeline's info, then the markers; `confirm` is asked when the lengths differ by more than a second.
    /// `owner`: the asset a comment id belongs to, nil when no comment has it (deleted).
    static func send(_ asset: Deliver.Asset, _ version: Deliver.Version, comments: [Deliver.Comment], openOnly: Bool, includeInternal: Bool,
                     owner: @MainActor (UUID) -> UUID? = { DeliverStore.shared.comment($0)?.asset },
                     confirm: (String) async -> Bool) async throws -> Result? {
        guard let probe = version.probe else { throw Failure(message: String(localized: "This version has no frames to mark.")) }
        let info: [String: Any]
        do { info = try await bridge(["action": "timelineInfo"]) } catch {
            throw Failure(message: String(localized: "Open the timeline in DaVinci Resolve first"))
        }
        guard let name = info["timeline"] as? String, let rate = (info["rate"] as? NSNumber)?.doubleValue, rate > 0 else {
            throw Failure(message: String(localized: "Open the timeline in DaVinci Resolve first"))
        }
        let start = info["start"] as? Int ?? 0, end = info["end"] as? Int ?? start
        let timelineFrames = end - start, versionFrames = Int((Double(probe.frames) * factor(rate: rate, probe: probe)).rounded())
        if abs(timelineFrames - versionFrames) > Int(rate.rounded()) {
            let a = DeliverTimecode.duration(Double(timelineFrames) / rate), b = DeliverTimecode.duration(probe.duration)
            guard await confirm(String(localized: "The open timeline \(name) is \(a) long; this video is \(b). Add markers anyway?")) else { return nil }
        }
        let ours = markers(comments, probe: probe, rate: rate, openOnly: openOnly, includeInternal: includeInternal)
        // This asset's Pluck markers (any version) and those of deleted comments go before the new ones are added
        // (a comment since resolved or left out this time too), so their frames aren't taken. Other assets' stay.
        let there = info["markers"] as? [[String: Any]] ?? []
        let mine = Set(comments.map(\.id))
        let old = Set(there.compactMap { $0["data"] as? String }.filter { data in
            guard data.hasPrefix("pluck:") else { return false }
            guard let id = UUID(uuidString: String(data.dropFirst(6))), !mine.contains(id) else { return true }
            return owner(id).map { $0 == asset.id } ?? true
        })
        let occupied = Set(there.compactMap { marker -> Int? in
            guard let frame = marker["frame"] as? Int, !old.contains(marker["data"] as? String ?? "") else { return nil }
            return frame
        })
        let (placed, moved, skipped) = place(ours, occupied: occupied)
        let answer = try await bridge(["action": "addMarkers", "markers": placed.map(\.json), "remove": old.sorted()])
        return Result(timeline: name, added: answer["added"] as? Int ?? 0, moved: moved + (answer["moved"] as? [String] ?? []),
                      skipped: skipped + (answer["skipped"] as? [String] ?? []))
    }
}

/// "Send to Resolve timeline": the two options, then what was added.
struct DeliverResolveMarkersSheet: View {
    let asset: Deliver.Asset
    let version: Deliver.Version
    @Environment(\.dismiss) private var dismiss
    @State private var openOnly = true
    @State private var includeInternal = false
    @State private var working = false
    @State private var result: String?
    @State private var problem: String?
    @State private var question: String?
    @State private var answer: CheckedContinuation<Bool, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to Resolve timeline").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            StudioSwitchRow(title: "Open comments only", isOn: $openOnly)
            StudioSwitchRow(title: "Include internal", isOn: $includeInternal)
            if let question {
                Text(verbatim: question).font(Design.Studio.body).foregroundStyle(Design.Studio.text).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { reply(false) }.buttonStyle(StudioFlatButtonStyle())
                    Button("Add Markers") { reply(true) }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                }
            }
            if let result { Text(verbatim: result).font(Design.Studio.body).foregroundStyle(Design.Studio.good) }
            if let problem { Text(verbatim: problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.bad) }
            HStack {
                if working { PlumSpinner() }
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
                if result == nil, question == nil { Button("Send") { Task { await send() } }.buttonStyle(StudioFlatButtonStyle(prominent: true)).disabled(working) }
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 400)
        .background(Design.Studio.panel)
    }

    private func reply(_ yes: Bool) {
        question = nil
        answer?.resume(returning: yes)
        answer = nil
    }

    private func send() async {
        working = true
        defer { working = false }
        problem = nil
        do {
            let comments = DeliverStore.shared.comments(asset.id, version: version.id)
            guard let done = try await DeliverResolveMarkers.send(asset, version, comments: comments, openOnly: openOnly, includeInternal: includeInternal, confirm: { text in
                await withCheckedContinuation { continuation in
                    question = text
                    answer = continuation
                }
            }) else { return }
            result = String(localized: "Added \(done.added) markers to \(done.timeline)")
            if !done.skipped.isEmpty { problem = String(localized: "\(done.skipped.count) skipped: their frames had markers already.") }
        } catch {
            problem = error.localizedDescription
        }
    }
}
