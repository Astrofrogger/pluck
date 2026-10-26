import AppKit
import SwiftUI

/// The end-of-day numbers of a project (cards, size, hours of footage, per person and camera),
/// live in Offload and as a PDF in the offload report's look.
struct WrapStats {
    /// A running total.
    struct Tally: Equatable {
        var cards = 0
        var bytes: Int64 = 0
        /// Seconds of footage (0 while the clip details aren't worked out).
        var duration: Double = 0
    }

    var cards = 0
    var bytes: Int64 = 0
    var duration: Double = 0
    var perOperator: [UUID: Tally] = [:]
    var perCamera: [String: Tally] = [:]
    var problems = 0

    /// Who offloaded the most cards (the most bytes, on a tie).
    var busiest: UUID? {
        perOperator.max { ($0.value.cards, $0.value.bytes) < ($1.value.cards, $1.value.bytes) }?.key
    }
}

enum OffloadWrap {
    /// The project's cards in a range of days (all of them when nil). The footage time comes from
    /// the clip details, where they're worked out.
    @MainActor static func stats(project: OffloadProject, jobs: [OffloadJob], days: ClosedRange<Date>?,
                                 details: @MainActor (UUID) -> [ClipDetails]? = { OffloadCenter.shared.details(for: $0) }) -> WrapStats {
        var result = WrapStats()
        for job in cards(project, jobs, days) {
            let seconds = details(job.id)?.reduce(0) { $0 + ($1.duration ?? 0) } ?? 0
            result.cards += 1
            result.bytes += job.totalBytes
            result.duration += seconds
            result.problems += job.problems.count
            func add(_ tally: inout WrapStats.Tally) { tally.cards += 1; tally.bytes += job.totalBytes; tally.duration += seconds }
            if let who = job.operatorID { add(&result.perOperator[who, default: .init()]) }
            add(&result.perCamera[cameraName(job), default: .init()])
        }
        return result
    }

    /// The project's finished-or-running cards started in the range, oldest first.
    static func cards(_ project: OffloadProject, _ jobs: [OffloadJob], _ days: ClosedRange<Date>?) -> [OffloadJob] {
        jobs.filter { $0.project == project.id && (days?.contains($0.started) ?? true) }.sorted { $0.started < $1.started }
    }

    static func cameraName(_ job: OffloadJob) -> String { job.camera ?? String(localized: "Camera") }

    /// All of one calendar day.
    static func range(of day: Date) -> ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: day)
        return start...(Calendar.current.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-0.001))
    }

    /// The days the project has cards on, oldest first.
    static func days(_ project: OffloadProject, _ jobs: [OffloadJob]) -> [Date] {
        Set(jobs.filter { $0.project == project.id }.map { Calendar.current.startOfDay(for: $0.started) }).sorted()
    }

    static func hours(_ seconds: Double) -> String {
        seconds > 0 ? Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : "—"
    }

    // MARK: - The PDF

    /// The wrap report of a range of days (nil: all of them), as a PDF.
    @MainActor static func pdf(project: OffloadProject, jobs: [OffloadJob], days: ClosedRange<Date>?,
                               details: @MainActor (UUID) -> [ClipDetails]? = { OffloadCenter.shared.details(for: $0) }) -> Data {
        let list = cards(project, jobs, days)
        let totals = stats(project: project, jobs: jobs, days: days, details: details)
        let first = project.firstOffload(in: jobs)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin

        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ colour: NSColor = .black, after: CGFloat = 4, style: NSParagraphStyle? = nil) {
            let paragraph = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacing = after
            text.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]))
        }

        // Title: the project, and the day or the days.
        var when = String(localized: "All days")
        if let days {
            let one = Calendar.current.isDate(days.lowerBound, inSameDayAs: days.upperBound)
            let number = project.day(of: days.lowerBound, firstOffload: first)
            when = one ? String(localized: "Day \(number)") + " · " + days.lowerBound.formatted(date: .long, time: .omitted)
                : days.lowerBound.formatted(date: .abbreviated, time: .omitted) + " – " + days.upperBound.formatted(date: .abbreviated, time: .omitted)
        } else if let first, let last = list.last?.started {
            when = first.formatted(date: .abbreviated, time: .omitted) + " – " + last.formatted(date: .abbreviated, time: .omitted)
        }
        add(String(localized: "Wrap Report"), .systemFont(ofSize: 11, weight: .medium), .gray, after: 2)
        add(project.name, .systemFont(ofSize: 22, weight: .bold), after: 2)
        add(when, .systemFont(ofSize: 12), .gray, after: 14)

        // Tables are tab-separated: a name, then numbers lined up on the right.
        func style(_ stops: [(CGFloat, NSTextAlignment)]) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = stops.map { NSTextTab(textAlignment: $0.1, location: $0.0) }
            paragraph.lineBreakMode = .byTruncatingTail
            return paragraph
        }
        let totalsStyle = style([(90, .left)])
        let size = ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file)
        let facts: [(String, String)] = [
            (String(localized: "Cards"), "\(totals.cards)"),
            (String(localized: "Size"), size),
            (String(localized: "Footage"), hours(totals.duration)),
            (String(localized: "Result"), totals.problems == 0 ? String(localized: "Every file matches on every drive.")
                : String(localized: "\(totals.problems) files couldn’t be copied.")),
        ]
        for (label, value) in facts {
            let paragraph = (totalsStyle.mutableCopy() as! NSMutableParagraphStyle)
            paragraph.paragraphSpacing = 3
            text.append(NSAttributedString(string: label + "\t", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                                .foregroundColor: NSColor.gray, .paragraphStyle: paragraph]))
            let colour: NSColor = label == String(localized: "Result") ? (totals.problems == 0 ? .systemGreen : .systemOrange) : .black
            text.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: colour,
                                                                              .paragraphStyle: paragraph]))
        }

        let columns = style([(width - 190, .right), (width - 110, .right), (width, .right)])
        func table(_ title: String, _ rows: [(String, WrapStats.Tally)]) {
            guard !rows.isEmpty else { return }
            add("", .systemFont(ofSize: 6))
            add(title, .systemFont(ofSize: 11, weight: .semibold), after: 3)
            add([String(localized: "Name"), String(localized: "Cards"), String(localized: "Size"), String(localized: "Footage")].joined(separator: "\t"),
                .systemFont(ofSize: 8, weight: .semibold), .gray, after: 2, style: columns)
            for (name, tally) in rows {
                let line = [name, "\(tally.cards)", ByteCountFormatter.string(fromByteCount: tally.bytes, countStyle: .file), hours(tally.duration)]
                add(line.joined(separator: "\t"), .systemFont(ofSize: 9), after: 2, style: columns)
            }
        }
        table(String(localized: "Per Person"), project.operators.compactMap { person in
            totals.perOperator[person.id].map { ("\(person.letter) · \(person.name)", $0) }
        })
        table(String(localized: "Per Camera"), totals.perCamera.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })

        // Every card, with whether it was checked.
        add("", .systemFont(ofSize: 6))
        add(String(localized: "Cards"), .systemFont(ofSize: 11, weight: .semibold), after: 3)
        for job in list {
            let good = job.finished != nil && job.problems.isEmpty && job.isComplete
            let size = ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
            add("\(job.displayName)\t\(cameraName(job))\t\(size)\t" + (good ? "✓ " + String(localized: "Checked") : "! " + String(localized: "Not checked")),
                .systemFont(ofSize: 9), after: 2,
                style: style([(230, .left), (width - 70, .right), (width, .right)]))
            let mark = (text.string as NSString).range(of: good ? "✓" : "!", options: .backwards)
            if mark.location != NSNotFound { text.addAttribute(.foregroundColor, value: good ? NSColor.systemGreen : NSColor.systemOrange,
                                                          range: NSRange(location: mark.location, length: text.length - mark.location - 1)) }
        }

        // What couldn't be copied.
        let failed = list.flatMap { job in job.problems.map { (job.displayName, $0) } }
        if !failed.isEmpty {
            add("", .systemFont(ofSize: 6))
            add(String(localized: "Problems"), .systemFont(ofSize: 11, weight: .semibold), after: 3)
            for (name, file) in failed {
                add("\(name) · \(file.path): \(file.problem ?? "")", .systemFont(ofSize: 8), .systemOrange, after: 2)
            }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        add("", .systemFont(ofSize: 6))
        add(String(localized: "Made with Pluck \(version)."), .systemFont(ofSize: 8), .gray)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(text)
        view.backgroundColor = .white
        view.appearance = NSAppearance(named: .aqua)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        let data = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
        return data as Data
    }

    // MARK: - Saving and sharing

    static func fileName(_ project: OffloadProject, days: ClosedRange<Date>?) -> String {
        let when = days.map { $0.lowerBound.formatted(.iso8601.year().month().day()) } ?? String(localized: "All days")
        return FolderTemplate.safe("\(project.name) Wrap \(when).pdf")
    }

    /// Asks where to keep the report.
    @MainActor static func save(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Opens the share sheet for the report.
    @MainActor static func share(_ data: Data, name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-wrap-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? data.write(to: url, options: .atomic)) != nil, let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}

/// Today's numbers of a project in one line, and the button for its wrap report.
struct OffloadWrapStrip: View {
    let project: OffloadProject
    @State private var center = OffloadCenter.shared

    private var jobs: [OffloadJob] { center.jobs.filter { $0.project == project.id } }
    private var today: WrapStats { OffloadWrap.stats(project: project, jobs: jobs, days: OffloadWrap.range(of: .now)) }

    var body: some View {
        let stats = today
        HStack(spacing: Design.Spacing.controls) {
            Label("\(stats.cards) · \(ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)) · \(OffloadWrap.hours(stats.duration))",
                  systemImage: "sum")
            if let busiest = stats.busiest, let person = project.person(busiest), project.operators.count > 1 {
                Label(person.name, systemImage: "person.fill")
            }
            Spacer()
            OffloadBackupButton(project: project)
            Menu {
                ForEach([(String(localized: "Save…"), false), (String(localized: "Share…"), true)], id: \.1) { title, share in
                    Menu(title) {
                        Button("Today") { make(OffloadWrap.range(of: .now), share: share) }
                        Button("All Days") { make(nil, share: share) }
                        let first = project.firstOffload(in: jobs)
                        let days = OffloadWrap.days(project, jobs)
                        if !days.isEmpty { Divider() }
                        ForEach(days, id: \.self) { day in
                            Button(String(localized: "Day \(project.day(of: day, firstOffload: first))") + " · " + day.formatted(date: .abbreviated, time: .omitted)) {
                                make(OffloadWrap.range(of: day), share: share)
                            }
                        }
                    }
                }
            } label: {
                Label("Wrap Report", systemImage: "doc.text")
            } primaryAction: {
                make(OffloadWrap.range(of: .now), share: false)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(jobs.isEmpty)
            .help("A PDF of the day: every card and whether it was checked, per person and camera. Click for today; the arrow has other days and sharing.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .task(id: jobs.count) { for job in jobs { await center.loadDetails(job.id) } }
    }

    private func make(_ days: ClosedRange<Date>?, share: Bool) {
        let data = OffloadWrap.pdf(project: project, jobs: center.jobs, days: days)
        let name = OffloadWrap.fileName(project, days: days)
        if share { OffloadWrap.share(data, name: name) } else { OffloadWrap.save(data, name: name) }
    }
}
