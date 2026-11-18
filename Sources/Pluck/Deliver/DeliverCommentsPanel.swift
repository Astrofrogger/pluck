import SwiftUI

/// The comments on a version: open or completed, searched, filtered (author, #tag, drawings, internal) and sorted,
/// each with where it is (timecode, page or general; a click seeks there and shows its drawing and pin), reactions,
/// replies and a complete box; the composer at the foot ("Comment at 01:00:04:12"), and the export menu.
struct DeliverCommentsPanel: View {
    let asset: Deliver.Asset
    let version: Deliver.Version
    let playback: DeliverPlayback
    @Binding var selected: UUID?
    @Binding var drawing: Deliver.Drawing
    @Binding var drawingOn: Bool
    @Binding var markIn: Int?
    var anchor: Binding<[Double]?> = .constant(nil)
    var pinning: Binding<Bool> = .constant(false)
    /// Documents: the page shown (comments are stamped with it).
    var page: Int? = nil
    @State private var store = DeliverStore.shared
    @State private var text = ""
    @State private var completedShown = false
    @State private var replyTo: UUID?
    @State private var reply = ""
    @State private var search = ""
    @State private var author: String?
    @State private var tag: String?
    @State private var drawingsOnly = false
    @State private var internalOnly = false
    @State private var general = false
    @State private var isInternal = false
    @AppStorage("deliverCommentSort") private var sort = "time"
    @AppStorage("deliverDrawTool") private var toolName = Deliver.Drawing.Tool.pen.rawValue
    @AppStorage("deliverDrawColour") private var colour = Deliver.Drawing.palette[0]
    @FocusState private var typing: Bool
    @State private var naming = false
    @AppStorage(DeliverSettings.askedKey) private var asked = false

    private var all: [Deliver.Comment] {
        _ = store.commentsChanged
        return store.comments(asset.id, version: version.id)
    }

    /// What's shown: the open/completed switch, the search and the filters, in the chosen order (exports take this).
    var shown: [Deliver.Comment] { Self.filter(all, completed: completedShown, search: search, author: author, tag: tag, drawings: drawingsOnly, internalOnly: internalOnly, sort: sort) }

    static func filter(_ list: [Deliver.Comment], completed: Bool?, search: String, author: String?, tag: String?, drawings: Bool, internalOnly: Bool, sort: String) -> [Deliver.Comment] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let kept = list.filter { comment in
            (completed == nil || comment.completed == completed) && (author == nil || comment.author == author) && (tag == nil || comment.tags.contains(tag!))
                && (!drawings || comment.drawing != nil) && (!internalOnly || comment.isInternal)
                && words.allSatisfy { word in comment.text.lowercased().contains(word) || comment.author.lowercased().contains(word)
                    || comment.replies.contains { $0.text.lowercased().contains(word) } }
        }
        switch sort {
        case "date": return kept.sorted { $0.created > $1.created }
        case "author": return kept.sorted { ($0.author.lowercased(), $0.position) < ($1.author.lowercased(), $1.position) }
        default: return kept
        }
    }

    private var clip: DeliverExport.Clip { .init(name: asset.name, version: version.number, probe: version.probe) }

    private func timecode(_ frame: Int) -> String { clip.timecode(frame) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                StudioSegmented(options: [(false, "Open"), (true, "Completed")], selection: $completedShown)
                Spacer()
                filterMenu
                exportMenu
                // Your name on comments: a click changes it.
                Button { naming.toggle() } label: { Text(verbatim: DeliverSettings.author).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
                    .buttonStyle(.plain).help("Your name on comments")
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet)
                TextField("Search comments", text: $search).textFieldStyle(.plain).font(Design.Studio.body)
                if let chip = author ?? tag.map({ "#" + $0 }) {
                    Button { author = nil; tag = nil } label: { StudioChip(text: Text(verbatim: chip), symbol: "xmark") }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 8)
            DeliverNamePrompt(editing: $naming).padding(.horizontal, 12)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 8) {
                        let comments = shown
                        if comments.isEmpty {
                            Text(completedShown ? "Nothing completed" : "No comments yet").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).padding(.top, 40)
                        }
                        ForEach(comments) { comment in row(comment).id(comment.id) }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear { if let selected { reader.scrollTo(selected) } }
            }
            composer
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                Text("Timecode").tag("time")
                Text("Newest").tag("date")
                Text("Author").tag("author")
            }
            Divider()
            Toggle("With Drawings", isOn: $drawingsOnly)
            Toggle("Internal Only", isOn: $internalOnly)
            let authors = Array(Set(all.map(\.author))).sorted()
            if !authors.isEmpty {
                Menu("Author") { ForEach(authors, id: \.self) { name in Button { author = name } label: { Text(verbatim: name) } } }
            }
            let tags = Array(Set(all.flatMap(\.tags))).sorted()
            if !tags.isEmpty {
                Menu("Tag") { ForEach(tags, id: \.self) { name in Button { tag = name } label: { Text(verbatim: "#" + name) } } }
            }
        } label: {
            Image(systemName: drawingsOnly || internalOnly || author != nil || tag != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .foregroundStyle(Design.Studio.textQuiet)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Filter and sort")
    }

    private var exportMenu: some View {
        Menu {
            ForEach(DeliverExport.Format.allCases.filter { !$0.timeline || asset.kind == .video || asset.kind == .audio }) { format in
                Button(format.title) { DeliverExport.save(format, shown, asset: asset, version: version) }
            }
        } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(Design.Studio.textQuiet) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Export comments")
    }

    private func row(_ comment: Deliver.Comment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { selected = comment.id } label: {
                    Text(verbatim: clip.place(comment))
                        .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.text)
                        .padding(.horizontal, 6).frame(height: 18).background(Design.Studio.raised, in: .capsule)
                }
                .buttonStyle(.plain)
                Button { author = comment.author } label: { Text(verbatim: comment.author).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1) }
                    .buttonStyle(.plain)
                if comment.isInternal { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Design.Studio.warn).help("Internal: only your team sees it") }
                if comment.drawing != nil { Image(systemName: "scribble").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet) }
                if comment.anchor != nil { Image(systemName: "mappin").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet) }
                if !(comment.attachments ?? []).isEmpty { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet) }
                Spacer()
                Button { try? store.complete(comment.id, !comment.completed) } label: {
                    Image(systemName: comment.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(comment.completed ? Design.Studio.good : Design.Studio.textQuiet)
                }
                .buttonStyle(.plain).help(comment.completed ? "Open again" : "Complete")
            }
            Text(verbatim: comment.text).font(Design.Studio.body).foregroundStyle(Design.Studio.text).fixedSize(horizontal: false, vertical: true)
            if !comment.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(comment.tags, id: \.self) { name in
                        Button { tag = name } label: { StudioChip(text: Text(verbatim: "#" + name), colour: Self.tagColour(name), tinted: true) }.buttonStyle(.plain)
                    }
                }
            }
            reactions(comment)
            ForEach(comment.replies) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: item.author).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                        if item.isInternal { StudioChip(text: Text("Internal"), symbol: "lock.fill", colour: Design.Studio.warn, tinted: true).help("Internal: only your team sees it") }
                    }
                    Text(verbatim: item.text).font(Design.Studio.body).foregroundStyle(Design.Studio.text).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Design.Studio.line).frame(width: 2) }
            }
            if replyTo == comment.id {
                HStack {
                    TextField("Reply", text: $reply).textFieldStyle(.plain).font(Design.Studio.body)
                        .onSubmit { send(reply: comment.id) }
                    Button("Send") { send(reply: comment.id) }.buttonStyle(StudioFlatButtonStyle()).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: 12) {
                    Button("Reply") { replyTo = comment.id; reply = "" }
                    Button("Delete", role: .destructive) { _ = try? store.deleteComment(comment.id) }
                }
                .buttonStyle(.plain).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .padding(10)
        .studioBox(outline: selected == comment.id ? Design.Brand.pink : nil)
        .contentShape(.rect)
        .onTapGesture { selected = comment.id }
    }

    /// The reactions on a comment (a click turns the owner's on or off) and a menu to add one.
    private func reactions(_ comment: Deliver.Comment) -> some View {
        HStack(spacing: 4) {
            ForEach(DeliverServer.reactions(comment, mine: "owner").indices, id: \.self) { index in
                let item = DeliverServer.reactions(comment, mine: "owner")[index]
                let emoji = item["emoji"] as? String ?? "", mine = item["mine"] as? Bool ?? false
                Button { _ = try? store.react(comment.id, emoji: emoji, by: "owner", on: !mine) } label: {
                    Text(verbatim: "\(emoji) \(item["count"] as? Int ?? 0)").font(Design.Studio.hint)
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(mine ? Design.Brand.pink.opacity(0.25) : Design.Studio.raised, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(Deliver.Comment.emoji, id: \.self) { emoji in
                    Button { _ = try? store.react(comment.id, emoji: emoji, by: "owner", on: true) } label: { Text(verbatim: emoji) }
                }
            } label: { Image(systemName: "face.smiling").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("React")
        }
    }

    /// A #FF0000-style tag shows its colour; others a steady colour from the palette.
    static func tagColour(_ tag: String) -> Color {
        if tag.count == 6, UInt32(tag, radix: 16) != nil { return Color(hex: "#" + tag) }
        return Color(hex: Deliver.Drawing.palette[abs(tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 6])
    }

    private func send(reply id: UUID) {
        guard asked else { naming = true; return }
        guard (try? store.reply(to: id, text: reply, author: DeliverSettings.author)) != nil else { return }
        replyTo = nil
        reply = ""
    }

    private var placeHint: String {
        if general || asset.kind == .other { return String(localized: "General comment") }
        if let page { return String(localized: "Comment on page \(page)") }
        if asset.kind == .image { return String(localized: "Comment") }
        return String(localized: "Comment at \(timecode(markIn ?? playback.frame))")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if drawingOn {
                HStack(spacing: 4) {
                    ForEach(Deliver.Drawing.Tool.allCases, id: \.self) { tool in
                        Button { toolName = tool.rawValue } label: {
                            Image(systemName: Self.symbol(tool)).font(.system(size: 12)).frame(width: 22, height: 22)
                                .background(toolName == tool.rawValue ? Design.Studio.line : .clear, in: .rect(cornerRadius: 5))
                        }
                        .buttonStyle(.plain).foregroundStyle(Design.Studio.text)
                    }
                    Spacer(minLength: 4)
                    ForEach(Deliver.Drawing.palette, id: \.self) { hex in
                        Button { colour = hex } label: {
                            Circle().fill(Color(hex: hex)).frame(width: 12, height: 12)
                                .overlay { Circle().stroke(colour == hex ? Design.Studio.text : Design.Studio.line, lineWidth: colour == hex ? 2 : 1).padding(-2) }
                        }
                        .buttonStyle(.plain)
                    }
                    Button { if !drawing.strokes.isEmpty { drawing.strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet).help("Undo")
                }
            }
            TextField(text: $text, axis: .vertical) { Text(verbatim: placeHint) }
                .textFieldStyle(.plain).font(Design.Studio.body).lineLimit(1...5)
                .focused($typing)
                .onChange(of: typing) { if typing, playback.playing { playback.toggle() } }
            HStack(spacing: 10) {
                if asset.kind == .video || asset.kind == .audio {
                    Button { markIn = markIn == nil ? playback.frame : nil } label: {
                        Image(systemName: markIn == nil ? "arrow.left.and.line.vertical.and.arrow.right" : "xmark")
                    }
                    .help(markIn == nil ? "Mark in here: the comment runs to the playhead" : "No range")
                    .disabled(general)
                    Button { general.toggle(); if general { markIn = nil } } label: { Image(systemName: "text.alignleft") }
                        .foregroundStyle(general ? Design.Brand.pink : Design.Studio.textQuiet)
                        .help("General comment, not at a time")
                }
                if asset.kind != .audio && asset.kind != .other {
                    Button { drawingOn.toggle(); if !drawingOn { drawing = .init(strokes: []) } } label: { Image(systemName: "pencil.tip") }
                        .foregroundStyle(drawingOn ? Design.Brand.pink : Design.Studio.textQuiet)
                        .help("Draw on the frame")
                    Button { pinning.wrappedValue.toggle(); if !pinning.wrappedValue { anchor.wrappedValue = nil } } label: { Image(systemName: "mappin") }
                        .foregroundStyle(pinning.wrappedValue || anchor.wrappedValue != nil ? Design.Brand.pink : Design.Studio.textQuiet)
                        .help("Pin a point on the picture")
                }
                Button { isInternal.toggle() } label: { Image(systemName: isInternal ? "lock.fill" : "lock.open") }
                    .foregroundStyle(isInternal ? Design.Studio.warn : Design.Studio.textQuiet)
                    .help(isInternal ? "Internal: only your team sees it" : "Everyone on the link sees it")
                Spacer()
                Button("Comment") { post() }.buttonStyle(StudioFlatButtonStyle(prominent: true))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
        }
        .padding(12)
        .background(Design.Studio.backdrop.opacity(0.5))
    }

    private func post() {
        // The first comment asks for a name (once; skipping keeps "Editor").
        guard asked else { naming = true; return }
        let timed = (asset.kind == .video || asset.kind == .audio) && !general
        let at = markIn.map { min($0, playback.frame) } ?? playback.frame
        let end = markIn.map { max($0, playback.frame) }
        let frame: Int? = asset.kind == .image ? 0 : timed ? at : nil
        let made = try? store.addComment(asset: asset.id, version: version.id, frame: frame, endFrame: timed && end != at ? end : nil,
                                         text: text, author: DeliverSettings.author, drawing: drawing.strokes.isEmpty ? nil : drawing,
                                         page: asset.kind == .document ? page ?? 1 : nil, anchor: anchor.wrappedValue, isInternal: isInternal)
        guard made != nil else { return }
        text = ""
        markIn = nil
        drawing = .init(strokes: [])
        drawingOn = false
        anchor.wrappedValue = nil
        pinning.wrappedValue = false
        general = false
    }

    static func symbol(_ tool: Deliver.Drawing.Tool) -> String {
        switch tool {
        case .pen: "scribble"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        }
    }
}

/// "Your name on comments", asked the first time the owner comments or shares (and whenever they click their
/// name): saved for every comment after; Skip keeps "Editor". Shown only while it's needed.
struct DeliverNamePrompt: View {
    var editing: Binding<Bool>? = nil
    @AppStorage(DeliverSettings.authorKey) private var name = ""
    @AppStorage(DeliverSettings.askedKey) private var asked = false
    @State private var typed = ""

    var body: some View {
        if !asked || editing?.wrappedValue == true {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name on comments").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                HStack(spacing: 8) {
                    TextField("Editor", text: $typed).settingField(width: 140).onSubmit(save)
                    Button("Save", action: save).settingButton().fixedSize()
                    if !asked { Button("Skip") { asked = true; editing?.wrappedValue = false }.settingButton().fixedSize() }
                }
            }
            .padding(8)
            .studioBox()
            .onAppear { typed = name }
        }
    }

    private func save() {
        name = Deliver.clean(typed, limit: DeliverStore.authorLimit)
        asked = true
        editing?.wrappedValue = false
    }
}
