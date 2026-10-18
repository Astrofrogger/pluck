import SwiftUI

/// What matters about a clip, in plain words: the frame rate it plays at and was shot at, then
/// the picture, camera and recording, read from the metadata each format writes.
extension RawClipInfo {
    /// The rate the sensor ran at, when the camera says (RED's record rate, Blackmagic's sensor rate).
    var shotFps: Double? {
        if let n = Double(meta["record_framerate_numerator"] ?? ""), let d = Double(meta["record_framerate_denominator"] ?? ""), d > 0 {
            return n / d
        }
        for key in ["record_framerate", "sensor_rate", "Sensor Rate", "sensor_frame_rate"] {
            if let value = meta[key], let rate = RawClipDetails.rate(from: value) { return rate }
        }
        return nil
    }

    /// How much slower (above 1) or quicker (below 1) than real time it plays.
    var motion: Double? {
        guard let shot = shotFps, fps > 0, abs(shot / fps - 1) > 0.01 else { return nil }
        return shot / fps
    }

    fileprivate func value(_ keys: String...) -> String? {
        for key in keys {
            if let value = meta[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != "0" || key.hasPrefix("dropped") { return value }
        }
        return nil
    }

    var detailSections: [RawClipDetails.Section] {
        typealias Row = RawClipDetails.Row
        var picture: [Row] = [], camera: [Row] = [], recording: [Row] = []

        // Picture
        let size = "\(width)×\(height)"
        picture.append(Row(String(localized: "Resolution"), value("resolution_format_name").map { "\($0) · \(size)" } ?? size))
        if let redcode = value("redcode") {
            picture.append(Row(String(localized: "Codec"), "REDCODE \(redcode)"))
        } else if let ratio = value("compression_ratio", "Compression Ratio") {
            picture.append(Row(String(localized: "Codec"), "\(formatName) \(ratio)"))
        } else {
            picture.append(Row(String(localized: "Codec"), formatName))
        }
        if let squeeze = Double(value("pixel_aspect_ratio", "anamorphic") ?? ""), squeeze > 1.01 {
            picture.append(Row(String(localized: "Anamorphic"), "\(RawClipDetails.number(squeeze))×"))
        }
        if let degrees = value("shutter_degrees") {
            let fraction = value("shutter_fractions").map { " · 1/\($0)" } ?? ""
            picture.append(Row(String(localized: "Shutter"), "\(degrees)°\(fraction)"))
        } else if let shutter = value("shutter_value", "Shutter Angle", "shutter_angle") {
            picture.append(Row(String(localized: "Shutter"), shutter))
        }
        let seconds = Int(Double(frames) / max(fps, 1))
        picture.append(Row(String(localized: "Length"),
                           String(localized: "\(String(format: "%d:%02d", seconds / 60, seconds % 60)) · \(frames) frames")))

        // Camera
        if let model = self.camera {
            // The sensor too, unless it only repeats the camera's name (KOMODO 6K, KOMODO S35).
            let sensor = value("sensor_name").flatMap { sensor in
                sensor.split(separator: " ").first.map { model.localizedCaseInsensitiveContains($0) } == true ? nil : sensor
            }
            camera.append(Row(String(localized: "Camera"), [model, sensor].compactMap { $0 }.joined(separator: " · ")))
        }
        if let lens = value("lens_name", "lens_type", "Lens Type") { camera.append(Row(String(localized: "Lens"), lens)) }
        if let focal = value("lens_focal_length", "focal_length", "Focal Length") {
            camera.append(Row(String(localized: "Focal length"), focal.hasSuffix("mm") ? focal : "\(focal) mm"))
        }
        if let aperture = value("lens_aperture_label", "aperture", "Aperture") { camera.append(Row(String(localized: "Aperture"), aperture)) }
        if let iso = value("iso", "ISO") ?? self.iso.map(String.init) { camera.append(Row(String(localized: "ISO"), iso)) }
        if let kelvin = value("white_balance_kelvin") ?? self.kelvin.map({ "\(Int($0))" }) {
            let tint = value("white_balance_tint").flatMap(Double.init).flatMap { $0 == 0 ? nil : " · " + String(localized: "tint \(RawClipDetails.number($0))") } ?? ""
            camera.append(Row(String(localized: "White balance"), "\(kelvin) K\(tint)"))
        }

        // Recording
        if let recorded = RawClipDetails.date(value("local_date"), value("local_time")) ?? value("date_recorded", "Date Recorded") {
            recording.append(Row(String(localized: "Recorded"), recorded))
        }
        if let timecode, !timecode.isEmpty { recording.append(Row(String(localized: "Timecode"), timecode)) }
        if let absoluteTimecode, !absoluteTimecode.isEmpty, absoluteTimecode != timecode {
            recording.append(Row(String(localized: "Time of day"), absoluteTimecode))
        }
        if let reel = value("reel_id_full", "reel_name", "Reel Name") { recording.append(Row(String(localized: "Reel"), reel)) }
        if let scene = value("scene", "Scene") {
            let take = value("take", "Take").map { " · " + String(localized: "take \($0)") } ?? ""
            recording.append(Row(String(localized: "Scene"), scene + take))
        }
        if let position = value("camera_position", "camera_id") { recording.append(Row(String(localized: "Camera position"), position)) }
        if let dropped = Int(value("dropped_frame_count") ?? ""), dropped > 0 {
            recording.append(Row(String(localized: "Dropped frames"), "\(dropped)", warning: true))
        }
        if let missing = meta[String(localized: "Missing frames")] {
            recording.append(Row(String(localized: "Missing frames"), missing, warning: true))
        }

        return [RawClipDetails.Section(String(localized: "Picture"), picture),
                RawClipDetails.Section(String(localized: "Camera"), camera),
                RawClipDetails.Section(String(localized: "Recording"), recording)].filter { !$0.rows.isEmpty }
    }
}

enum RawClipDetails {
    struct Row: Identifiable {
        let label: String
        let value: String
        var warning = false
        var id: String { label }
        init(_ label: String, _ value: String, warning: Bool = false) {
            self.label = label; self.value = value; self.warning = warning
        }
    }

    struct Section: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
        init(_ title: String, _ rows: [Row]) { self.title = title; self.rows = rows }
    }

    /// A frame rate as people write it: 25, 23.976, 29.97, 59.94.
    static func rate(_ fps: Double) -> String {
        abs(fps - fps.rounded()) < 0.005 ? "\(Int(fps.rounded()))" : fps.formatted(.number.precision(.fractionLength(2...3)))
    }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }

    /// "50", "50.00", "48000/1001" as a rate.
    static func rate(from text: String) -> Double? {
        let parts = text.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let n = parts[0], let d = parts[1], d > 0 { return n / d }
        return Double(text.trimmingCharacters(in: CharacterSet(charactersIn: " fps")))
    }

    /// RED's 20260921 and 084401 as a date and time in the Mac's own way.
    static func date(_ day: String?, _ time: String?) -> String? {
        guard let day, day.count == 8 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = time?.count == 6 ? "yyyyMMddHHmmss" : "yyyyMMdd"
        guard let date = parser.date(from: day + (time?.count == 6 ? time! : "")) else { return nil }
        return date.formatted(date: .abbreviated, time: time?.count == 6 ? .shortened : .omitted)
    }
}

/// The frame rate, large, with how it was shot when that's different.
struct RawFrameRateView: View {
    let info: RawClipInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.controls) {
                (Text(RawClipDetails.rate(info.fps)).font(.title2.weight(.semibold).monospacedDigit())
                    + Text(verbatim: " fps").font(.callout).foregroundStyle(.secondary))
                Spacer(minLength: 0)
                if let motion = info.motion {
                    RawMotionBadge(motion: motion)
                }
            }
            if let shot = info.shotFps, info.motion != nil {
                Text("Shot at \(RawClipDetails.rate(shot)) fps").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .help("The rate the clip plays at, and the rate the camera recorded when that was different")
    }
}

/// "1.6× slow motion" or "2× fast motion".
struct RawMotionBadge: View {
    let motion: Double
    var compact = false

    var body: some View {
        let slow = motion > 1
        let factor = RawClipDetails.number(slow ? motion : 1 / motion)
        Label {
            if compact { Text(verbatim: "\(factor)×") }
            else if slow { Text("\(factor)× slow motion") }
            else { Text("\(factor)× fast motion") }
        } icon: {
            Image(systemName: slow ? "slowmo" : "hare")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Design.Brand.gradient))
        .help(slow ? Text("Shot faster than it plays: slow motion") : Text("Shot slower than it plays: fast motion"))
    }
}

/// The picture, camera and recording, then every key the clip has, to filter.
struct RawClipDetailsView: View {
    let info: RawClipInfo
    @Binding var showAll: Bool
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            ForEach(info.detailSections) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(row.value)
                                .foregroundStyle(row.warning ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                                .multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(2)
                        }
                    }
                }
            }
            if !info.meta.isEmpty {
                DisclosureGroup(isExpanded: $showAll) {
                    VStack(alignment: .leading, spacing: 3) {
                        if showAll {
                            TextField("Filter", text: $filter)
                                .textFieldStyle(.roundedBorder)
                                .focusEffectDisabled()
                                .padding(.bottom, 4)
                        }
                        ForEach(info.meta.keys.sorted().filter { key in
                            filter.isEmpty || key.localizedCaseInsensitiveContains(filter) || (info.meta[key] ?? "").localizedCaseInsensitiveContains(filter)
                        }, id: \.self) { key in
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: key).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(info.meta[key] ?? "").multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(3)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("All Metadata").font(.callout)
                }
            }
        }
        .font(.caption)
    }
}
