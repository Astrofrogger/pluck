import AppKit
import Quartz
import SwiftUI
import WebKit

/// A file's contents shown in place (the Library's details panel and gallery), so it can be looked at before it's moved or
/// opened: Markdown drawn as a page, everything else by Quick Look (PDFs, text and code, pictures, films, songs, documents
/// and any type an installed Quick Look extension knows).
struct FilePreview: View {
    let url: URL

    var body: some View {
        if FilePreview.isMarkdown(url) {
            MarkdownPreview(url: url)
        } else {
            QuickLookPreview(url: url)
        }
    }

    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) }

    /// Whether the details panel shows the contents (not a film or song: those keep their poster and Play).
    static func showsContents(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return true }
        return !(type.conforms(to: .movie) || type.conforms(to: .audio))
    }
}

/// Quick Look's own preview, in place.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// A Markdown file drawn as a page (headings, lists, code, quotes, tables, links), dark like the rest of Studio.
struct MarkdownPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        // (A file from anywhere: no scripts, and links leave for the browser instead of loading here.)
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        load(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url?.lastPathComponent != url.lastPathComponent || context.coordinator.shown != url { load(view); context.coordinator.shown = url }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var shown: URL?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let target = action.request.url, ["http", "https", "mailto"].contains(target.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(target) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    private func load(_ view: WKWebView) {
        // (At most 2 MB read: a preview, not an editor.)
        let data = (try? FileHandle(forReadingFrom: url)).flatMap { try? $0.read(upToCount: 2_000_000) } ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        // (Relative pictures and links resolve next to the file.)
        view.loadHTMLString(Markdown.page(Markdown.html(text)), baseURL: url.deletingLastPathComponent())
    }
}

/// A small Markdown to HTML converter for previews: the common parts (CommonMark's blocks and inline marks), not every edge case.
enum Markdown {
    static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file:; style-src 'unsafe-inline'"><style>
        :root { color-scheme: dark; }
        body { font: 13px -apple-system, sans-serif; line-height: 1.55; color: #e6e3ea; background: transparent; margin: 14px 18px; }
        h1,h2,h3,h4 { line-height: 1.25; margin: 1.1em 0 .4em; } h1 { font-size: 1.6em; } h2 { font-size: 1.3em; } h3 { font-size: 1.1em; }
        a { color: #d58ab0; } code { font: 12px ui-monospace, monospace; background: #2a2630; padding: 1px 4px; border-radius: 4px; }
        pre { background: #1d1a21; padding: 10px 12px; border-radius: 8px; overflow-x: auto; } pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding-left: 12px; border-left: 3px solid #4a4352; color: #b9b3c0; }
        table { border-collapse: collapse; } td, th { border: 1px solid #3a3440; padding: 4px 8px; } hr { border: 0; border-top: 1px solid #3a3440; }
        img { max-width: 100%; }
        </style></head><body>\(body)</body></html>
        """
    }

    static func html(_ text: String) -> String {
        var out: [String] = []
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { out.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>"); paragraph = [] } }
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix(String(trimmed.prefix(3))) { code.append(escape(next)) }
                out.append("<pre><code>" + code.joined(separator: "\n") + "</code></pre>")
            } else if trimmed.isEmpty {
                flush()
            } else if let level = heading(trimmed) {
                flush()
                out.append("<h\(level)>" + inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)) + "</h\(level)>")
            } else if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flush(); out.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines.removeFirst().trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                out.append("<blockquote>" + html(quote.joined(separator: "\n")) + "</blockquote>")
            } else if let item = listItem(trimmed) {
                flush()
                let ordered = item.ordered
                var items = [item.text]
                while let next = lines.first, let more = listItem(next.trimmingCharacters(in: .whitespaces)), more.ordered == ordered {
                    lines.removeFirst(); items.append(more.text)
                }
                let tag = ordered ? "ol" : "ul"
                out.append("<\(tag)>" + items.map { "<li>" + inline($0) + "</li>" }.joined() + "</\(tag)>")
            } else if trimmed.hasPrefix("|"), let next = lines.first, next.contains("---") {
                flush()
                lines.removeFirst()
                func cells(_ row: String) -> [String] {
                    row.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                var table = "<table><tr>" + cells(trimmed).map { "<th>" + inline($0) + "</th>" }.joined() + "</tr>"
                while let row = lines.first, row.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    lines.removeFirst()
                    table += "<tr>" + cells(row).map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>"
                }
                out.append(table + "</table>")
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...6).contains(hashes) && line.dropFirst(hashes).first == " " ? hashes : nil
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) { return (false, String(line.dropFirst(2))) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return (true, String(line.dropFirst(digits.count + 2))) }
        return nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// A picture's address when it is next to the file or inline (no scheme, file: or data:); never one from the internet.
    static func localImage(_ src: String) -> Bool {
        if src.hasPrefix("//") { return false }
        guard let colon = src.firstIndex(of: ":"), !src[..<colon].contains("/") else { return true }
        return ["file", "data"].contains(src[..<colon].lowercased())
    }

    /// Code, pictures, links, bold, italic and strikethrough within a line.
    static func inline(_ text: String) -> String {
        var s = escape(text)
        func sub(_ pattern: String, _ make: @escaping ([String]) -> String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            var result = "", last = s.startIndex
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let whole = Range(m.range, in: s) else { continue }
                result += s[last..<whole.lowerBound]
                result += make((1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" })
                last = whole.upperBound
            }
            s = result + s[last...]
        }
        func sub(_ pattern: String, _ template: String) {
            s = (try? NSRegularExpression(pattern: pattern)).map { $0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template) } ?? s
        }
        sub("`([^`]+)`", "<code>$1</code>")
        // (Pictures next to the file only: one from the internet isn't fetched just by looking.)
        // (Quotes are escaped above, so nothing here can open an attribute; the scheme is compared in any case.)
        sub("!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)") { g in localImage(g[1]) ? "<img alt=\"\(g[0])\" src=\"\(g[1])\">" : "[\(g[0])]" }
        sub("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        sub("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>")
        sub("__([^_]+)__", "<strong>$1</strong>")
        sub("(?<![\\w*])\\*([^*]+)\\*(?![\\w*])", "<em>$1</em>")
        sub("(?<![\\w_])_([^_]+)_(?![\\w_])", "<em>$1</em>")
        sub("~~([^~]+)~~", "<del>$1</del>")
        return s
    }
}
