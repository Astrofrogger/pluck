import AppKit

/// A value on a Fusion node's input.
enum FusionValue {
    case number(Double)
    case point(Double, Double)
    case text(String)
    case id(String)
    /// Another node's output.
    case link(String, String = "Output")
    /// Worked out from other nodes (a Fusion expression), with a value until it is.
    case expression(String, Double)
    /// Animated: a value per frame (redundant frames dropped).
    case keys([(frame: Int, value: Double)])
    /// An animated point.
    case path([(frame: Int, x: Double, y: Double)])
    /// Written as it is (a gradient, say).
    case raw(String)
    /// A point worked out from other nodes, with a value until it is.
    case pointExpression(String, Double, Double)
}

/// A Fusion node graph, written out as a macro (a .setting) Resolve uses as a title: Text+ with
/// Followers, plates on masks, glows and merges, so everything stays editable there.
/// Points are in pixels from the frame's bottom left, as the templates draw.
final class FusionGraph {
    let canvas: CGSize
    let fps: Double
    /// The title's length in frames.
    let frames: Int
    private let clockAt: (Int) -> MotionClock
    private var tools: [String] = []
    private var used: Set<String> = []
    private var controls: [String] = []
    private var x = 0.0

    init(canvas: CGSize, fps: Double, duration: Double, speed: Double) {
        self.canvas = canvas
        self.fps = fps
        frames = max(Int((duration * fps).rounded()), 1)
        clockAt = { MotionClock(t: Double($0) / fps, duration: duration, speed: speed) }
    }

    /// A name no other node has.
    func name(_ base: String) -> String {
        var candidate = base, n = 1
        while used.contains(candidate) { n += 1; candidate = "\(base)\(n)" }
        used.insert(candidate)
        return candidate
    }

    /// Adds a node; returns its name.
    @discardableResult
    func add(_ type: String, _ base: String, _ inputs: [(String, FusionValue)], named: Bool = false,
             sliders: [(id: String, label: String)] = []) -> String {
        let node = named ? base : name(base)
        if named { used.insert(node) }
        var lines: [String] = []
        // Pictures and masks the size of the frame they're used in (the timeline's, in Resolve).
        let sized: Set<String> = ["Background", "TextPlus", "RectangleMask", "EllipseMask"]
        let inputs = sized.contains(type) ? [("UseFrameFormatSettings", FusionValue.number(1))] + inputs : inputs
        for (key, value) in inputs {
            lines.append("\t\t\t\t\(key) = \(input(value, node: node, key: key)),")
        }
        x += 110
        // Sliders of its own (a plate's extra width), for expressions elsewhere to read.
        let own = sliders.map {
            "\t\t\t\t\t\($0.id) = { LINKS_Name = \(quote($0.label)), LINKID_DataType = \"Number\", INPID_InputControl = \"SliderControl\", "
                + "INP_Default = 0, INP_MinScale = -400, INP_MaxScale = 800, ICS_ControlPage = \"Controls\" },"
        }
        let userControls = own.isEmpty ? "" : "\t\t\t\tUserControls = ordered() {\n\(own.joined(separator: "\n"))\n\t\t\t\t},\n"
        tools.append("""
        \t\t\t\(node) = \(type) {
        \t\t\t\tCtrlWZoom = false,
        \(userControls)\t\t\t\tInputs = {
        \(lines.map { "\t" + $0 }.joined(separator: "\n"))
        \t\t\t\t},
        \t\t\t\tViewInfo = OperatorInfo { Pos = { \(Int(x)), 0 } },
        \t\t\t},
        """)
        return node
    }

    private func input(_ value: FusionValue, node: String, key: String) -> String {
        switch value {
        case .number(let v): return "Input { Value = \(num(v)), }"
        case .point(let a, let b): return "Input { Value = { \(num(a)), \(num(b)) }, }"
        case .text(let s): return "Input { Value = \(quote(s)), }"
        case .id(let s): return "Input { Value = FuID { \(quote(s)) }, }"
        case .link(let op, let source): return "Input { SourceOp = \(quote(op)), Source = \(quote(source)), }"
        case .expression(let e, let v): return "Input { Value = \(num(v)), Expression = \(quote(e)), }"
        case .raw(let s): return "Input { Value = \(s), }"
        case .pointExpression(let e, let a, let b): return "Input { Value = { \(num(a)), \(num(b)) }, Expression = \(quote(e)), }"
        case .keys(let keys):
            let spline = name(node + key)
            tools.append(splineTool(spline, keys))
            return "Input { SourceOp = \(quote(spline)), Source = \"Value\", }"
        case .path(let keys):
            let path = name(node + key)
            let sx = name(path + "X"), sy = name(path + "Y")
            tools.append(splineTool(sx, keys.map { ($0.frame, $0.x) }))
            tools.append(splineTool(sy, keys.map { ($0.frame, $0.y) }))
            tools.append("""
            \t\t\t\(path) = XYPath {
            \t\t\t\tShowKeyPoints = false,
            \t\t\t\tDrawMode = "ModifyOnly",
            \t\t\t\tInputs = {
            \t\t\t\t\tX = Input { SourceOp = \(quote(sx)), Source = "Value", },
            \t\t\t\t\tY = Input { SourceOp = \(quote(sy)), Source = "Value", },
            \t\t\t\t},
            \t\t\t},
            """)
            return "Input { SourceOp = \(quote(path)), Source = \"Value\", }"
        }
    }

    private func splineTool(_ name: String, _ keys: [(frame: Int, value: Double)]) -> String {
        let frames = keys.map { "[\($0.frame)] = { \(num($0.value)), Flags = { Linear = true } }" }.joined(separator: ", ")
        return "\t\t\t\(name) = BezierSpline {\n\t\t\t\tSplineColor = { Red = 255, Green = 92, Blue = 107 },\n\t\t\t\tNameSet = true,\n\t\t\t\tKeyFrames = { \(frames) }\n\t\t\t},"
    }

    /// A control on the title in Resolve's inspector: one of a node's inputs, shown as `label`.
    /// `group`: inputs shown together (a colour's red, green, blue and alpha).
    func control(_ node: String, _ source: String, _ label: String? = nil, group: Int? = nil, page: String? = nil, defaultX: Double? = nil) {
        var fields = ["SourceOp = \(quote(node))", "Source = \(quote(source))"]
        if let label { fields.append("Name = \(quote(label))") }
        if let group { fields.append("ControlGroup = \(group)") }
        if let page { fields.append("Page = \(quote(page))") }
        controls.append("\t\t\t\tInput\(controls.count + 1) = InstanceInput { \(fields.joined(separator: ", ")), },")
    }

    /// The whole macro, `title` its name in Resolve, `output` the node that's the picture.
    func macro(title: String, output: String) -> String {
        let id = title.filter { $0.isLetter || $0.isNumber }
        return """
        {
        \tTools = ordered() {
        \t\t\(id) = MacroOperator {
        \t\t\tCtrlWZoom = false,
        \t\t\tNameSet = true,
        \t\t\tInputs = ordered() {
        \(controls.joined(separator: "\n"))
        \t\t\t},
        \t\t\tOutputs = {
        \t\t\t\tMainOutput1 = InstanceOutput { SourceOp = \(quote(output)), Source = "Output", },
        \t\t\t},
        \t\t\tViewInfo = GroupInfo { Pos = { 0, 0 } },
        \t\t\tTools = ordered() {
        \(tools.joined(separator: "\n"))
        \t\t\t},
        \t\t},
        \t},
        \tActiveTool = \(quote(id))
        }

        """
    }

    // MARK: Animation

    /// A value worked out for every frame (`f` from the template's clock), redundant frames
    /// dropped. A constant comes back as a plain number.
    func animate(_ f: (MotionClock) -> Double) -> FusionValue {
        let values = (0...frames).map { f(clockAt($0)) }
        guard let first = values.first, values.contains(where: { abs($0 - first) > 1e-6 }) else { return .number(values.first ?? 0) }
        return .keys(simplify(values))
    }

    /// A point worked out for every frame.
    func animatePoint(_ f: (MotionClock) -> CGPoint) -> FusionValue {
        let values = (0...frames).map { f(clockAt($0)) }
        let first = values[0]
        guard values.contains(where: { abs($0.x - first.x) > 1e-6 || abs($0.y - first.y) > 1e-6 }) else { return .point(first.x, first.y) }
        let xs = simplify(values.map { Double($0.x) }), ys = simplify(values.map { Double($0.y) })
        let kept = Set(xs.map { $0.frame }).union(ys.map { $0.frame }).sorted()
        return .path(kept.map { (frame: $0, x: Double(values[$0].x), y: Double(values[$0].y)) })
    }

    /// Frames a straight line between their neighbours wouldn't miss.
    private func simplify(_ values: [Double]) -> [(frame: Int, value: Double)] {
        let range = max((values.max() ?? 0) - (values.min() ?? 0), 1e-9)
        var kept: [(frame: Int, value: Double)] = [(0, values[0])]
        for i in 1..<values.count {
            if i == values.count - 1 { kept.append((i, values[i])); break }
            let a = kept.last!, b = values[i + 1]
            // Would a line from the last kept frame to the next one pass through this one?
            let span = Double(i + 1 - a.frame)
            let guess = a.value + (b - a.value) * Double(i - a.frame) / span
            if abs(guess - values[i]) > range * 0.002 { kept.append((i, values[i])) }
        }
        return kept
    }

    // MARK: Coordinates

    /// A point in the frame's own units (0 … 1 across and up).
    func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / canvas.width, y: p.y / canvas.height) }

    // MARK: Writing values

    private func num(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        return String(format: "%.6g", v)
    }

    private func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": break
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}
