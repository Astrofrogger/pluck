import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Library's share panel: turn sharing on, and what others need to get in (address, QR code
/// for a phone, access code).
struct LibrarySharingView: View {
    @State private var server = LibraryServer.shared
    @AppStorage(LibraryServer.enabledKey) private var enabled = false
    @AppStorage(LibraryServer.allowDownloadsKey) private var allowDownloads = false
    @AppStorage(LibraryServer.allowUploadsKey) private var allowUploads = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "dot.radiowaves.left.and.right", title: Text("Share on This Network"),
                        subtitle: Text("Phones and computers on the same network can browse, play and download your Library in a browser."),
                        subtitleIsName: false)
            Toggle("Share my Library", isOn: Binding(get: { enabled }, set: { server.setEnabled($0) }))
                .toggleStyle(.switch)

            if enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $allowDownloads) {
                        Text("Let them add downloads")
                        Text("A link sent from a phone or another Pluck downloads on this Mac.")
                    }
                    Toggle(isOn: $allowUploads) {
                        Text("Let them send files")
                        Text("Files sent from the page land in your Downloads folder and Library.")
                    }
                }
                if let problem = server.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if let address = server.numericAddress ?? server.address {
                    HStack(alignment: .top, spacing: Design.Spacing.section) {
                        if let qr = Self.qrCode(address) {
                            Image(decorative: qr, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .padding(8)
                                .background(.white, in: .rect(cornerRadius: Design.Radius.box))
                                .accessibilityLabel("QR code for \(address)")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Open") {
                                Text(address).textSelection(.enabled).font(.callout.monospaced())
                            }
                            if let name = server.address, name != address {
                                LabeledContent("or") {
                                    Text(name).textSelection(.enabled).font(.callout.monospaced())
                                }
                            }
                            LabeledContent("Access code") {
                                Text(server.code.chunked)
                                    .font(.title2.monospacedDigit().weight(.semibold))
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Button("Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(address, forType: .string)
                                }
                                Button("New Code") { server.newAccessCode() }
                                    .help("Everyone has to type the new code")
                            }
                        }
                    }
                    Text("Scan the code with your phone’s camera, or type the address in a browser.")
                        .noteStyle()
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Label(allowDownloads || allowUploads
                  ? "Nothing in your Library can be changed or deleted. Only devices on your own network, with the code, can get in. Sharing stops when Pluck quits."
                  : "Read-only: nothing can be changed or deleted. Only devices on your own network, with the code, can get in. Sharing stops when Pluck quits.",
                  systemImage: "lock.shield")
                .noteStyle()
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
    }

    /// A crisp QR code for the address.
    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

private extension String {
    /// "123456" → "123 456", easier to read out.
    var chunked: String {
        count == 6 ? prefix(3) + " " + suffix(3) : self
    }
}

/// Send to Phone: one file, a QR code, ten minutes.
struct SendToPhoneView: View {
    let entry: LibraryStore.Entry
    @State private var link: URL?
    @State private var failed = false
    @State private var expires = Date.now.addingTimeInterval(LibraryServer.sendLinkLifetime)

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "iphone.and.arrow.forward", title: Text("Send to Phone"), subtitle: Text(entry.title))
            if let link, let qr = LibrarySharingView.qrCode(link.absoluteString) {
                HStack(alignment: .center, spacing: Design.Spacing.section) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(.white, in: .rect(cornerRadius: Design.Radius.box))
                        .accessibilityLabel("QR code for this file")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with your phone’s camera to play or save it.")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, expires.timeIntervalSince(context.date))
                            Text(left > 0 ? String(localized: "Works for \(Duration.seconds(left.rounded()).formatted(.time(pattern: .minuteSecond))) more.")
                                          : String(localized: "This link has expired."))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if failed {
                Label("Pluck couldn’t start sharing on this network.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
            Label("Only this file, only on your own network. Your phone needs to be on the same Wi-Fi.", systemImage: "lock.shield")
                .noteStyle()
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 420)
        .task {
            link = await LibraryServer.shared.sendLink(for: entry.file)
            expires = .now.addingTimeInterval(LibraryServer.sendLinkLifetime)
            failed = link == nil
        }
    }
}
