import SwiftUI

/// How fast each drive wrote and the card read over the last moments (for the sparklines), and
/// which drive, if any, is holding the offload back.
struct SpeedHistory: Equatable {
    /// About ten seconds, at four a second.
    static let samples = 40
    /// A drive under this much of the fastest is slow.
    static let slowShare = 0.6
    /// For this long before it's said.
    static let slowFor: TimeInterval = 10

    /// MB/s for each drive, newest last.
    var drives: [[Double]]
    var card: [Double] = []
    /// The drive that has been under 60 % of the fastest for ten seconds.
    var holdingBack: Int?
    private var slow: Int?
    private var since: Date?

    init(drives: Int) { self.drives = Array(repeating: [], count: drives) }

    /// A new sample, in MB/s for each drive, then the card. A drive that wasn't written to in that
    /// moment (a file being checked) has none, and changes nothing.
    mutating func add(_ rates: [Double], at time: Date = .now) {
        guard rates.count == drives.count + 1 else { return }
        for index in drives.indices where rates[index] > 0 {
            drives[index].append(rates[index])
            if drives[index].count > Self.samples { drives[index].removeFirst() }
        }
        if let card = rates.last, card > 0 {
            self.card.append(card)
            if self.card.count > Self.samples { self.card.removeFirst() }
        }
        let active = drives.indices.filter { rates[$0] > 0 }
        guard active.count > 1, let fastest = active.map({ rates[$0] }).max(),
              let slowest = active.min(by: { rates[$0] < rates[$1] }) else { return }
        guard rates[slowest] < fastest * Self.slowShare else {
            slow = nil; since = nil; holdingBack = nil
            return
        }
        if slow != slowest { slow = slowest; since = time; holdingBack = nil }
        if let since, time.timeIntervalSince(since) >= Self.slowFor { holdingBack = slowest }
    }
}

/// A line of recent speeds, as small as a word.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let top = values.max(), top > 0 else { return }
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(SpeedHistory.samples - 1),
                                    y: size.height * (1 - CGFloat(value / top)) * 0.9 + 1)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 56, height: 14)
        .accessibilityHidden(true)
    }
}

/// The speeds in the running offload's row: a sparkline and the speed for the card and each
/// drive, and which drive is holding it back.
struct OffloadSpeedLine: View {
    let job: OffloadJob
    let history: SpeedHistory

    var body: some View {
        let names = job.speedNames
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Design.Spacing.controls) {
                if let last = history.card.last { entry(names.card, symbol: "sdcard", values: history.card, last: last, slow: false) }
                ForEach(names.drives.indices, id: \.self) { index in
                    if let last = history.drives[index].last {
                        entry(names.drives[index], symbol: "externaldrive", values: history.drives[index], last: last, slow: history.holdingBack == index)
                    }
                }
                Spacer(minLength: 0)
            }
            if let slow = history.holdingBack, names.drives.indices.contains(slow) {
                Label("\(names.drives[slow]) is holding this back", systemImage: "tortoise.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func entry(_ name: String, symbol: String, values: [Double], last: Double, slow: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Sparkline(values: values, tint: slow ? .orange : .accentColor)
            Text("\(Int(last.rounded())) MB/s").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(slow ? Color.orange : Color.secondary)
        .help(name)
    }
}
