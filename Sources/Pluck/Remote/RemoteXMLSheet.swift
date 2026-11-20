import AppKit
import SwiftUI

/// Files › Premiere Pro and Final Cut Pro: how to edit there with the proxies, and Render XML on the host Mac.
struct OtherEditorsGuide: View {
    @State private var open = false
    @State private var xml: (url: URL, text: String)?
    @State private var problem: String?

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Premiere Pro").font(Design.Studio.body.weight(.semibold))
                    Text("1. Mount the host’s drive, or pull the originals.")
                    Text("2. Import the originals.")
                    Text("3. Select them, then Proxy › Attach Proxies, and choose the pulled proxies folder.")
                    Text("4. To render on the host Mac: File › Export › Final Cut Pro XML, then Render XML here.")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Final Cut Pro").font(Design.Studio.body.weight(.semibold))
                    Text("1. Mount the host’s drive and import the originals, leaving the files in place.")
                    Text("2. File › Relink Files › Proxy, and choose the pulled proxies folder.")
                    Text("3. To render on the host Mac: File › Export XML, then Render XML here.")
                }
                HStack {
                    if let problem { Text(problem).foregroundStyle(Design.Studio.bad) }
                    Spacer()
                    Button("Render XML…", action: choose).buttonStyle(StudioFlatButtonStyle())
                        .help("The host Mac imports the XML into DaVinci Resolve and renders it from the originals")
                }
            }
            .font(Design.Studio.hint)
            .foregroundStyle(Design.Studio.textQuiet)
            .padding(.top, 6)
        } label: {
            Text("Premiere Pro and Final Cut Pro").font(Design.Studio.body)
        }
        .sheet(isPresented: Binding(get: { xml != nil }, set: { if !$0 { xml = nil } })) {
            if let xml { RemoteXMLSheet(url: xml.url, text: xml.text) }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = String(localized: "An XML exported from Premiere Pro or Final Cut Pro.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { xml = (url, try RemoteXML.read(url)); problem = nil } catch { problem = error.localizedDescription }
    }
}

/// What won't translate, the preset, then the send.
struct RemoteXMLSheet: View {
    let url: URL
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var model = RemoteResolve.shared
    @State private var preset = ""
    @State private var working = false
    @State private var message: String?

    private var timeline: String { RemoteXML.timeline(text) ?? url.deletingPathExtension().lastPathComponent }

    var body: some View {
        let missing = RemoteXML.untranslated(text)
        VStack(alignment: .leading, spacing: 14) {
            PaneHeader(title: Text("Render XML"), subtitle: Text("Cuts, speed, simple transitions and audio levels come over.")) {
                if working { PlumSpinner() }
            }
            Text(verbatim: timeline).font(Design.Studio.body)
            if missing.isEmpty {
                Text("Nothing found that won’t translate.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            } else {
                Text("These won’t look the same in Resolve:").font(Design.Studio.hint).foregroundStyle(Design.Studio.warn)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) { ForEach(missing, id: \.self) { Text($0) } }
                        .font(Design.Studio.hint).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            StudioField(label: "Preset") {
                Picker("Render preset", selection: $preset) { ForEach(model.presets, id: \.self) { Text($0).tag($0) } }.labelsHidden().fixedSize()
            }
            if let message { Text(message).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle(height: 32))
                Button("Render") { send() }
                    .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset.isEmpty || working)
            }
        }
        .foregroundStyle(Design.Studio.text)
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .task {
            if model.presets.isEmpty { try? await model.loadPresets() }
            if preset.isEmpty { preset = model.presets.first ?? "" }
        }
    }

    private func send() {
        working = true
        Task {
            defer { working = false }
            do {
                let unknown = try await model.renderXML(text, name: url.deletingPathExtension().lastPathComponent, timeline: timeline, preset: preset)
                if unknown.isEmpty { dismiss() } else {
                    message = String(localized: "Queued. These files aren’t this Mac’s proxies, so the host Mac looks for them as they are: \(unknown.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
