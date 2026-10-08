import AppKit
import WebKit

/// Fallback for pages yt-dlp doesn't understand: loads the page in an invisible web view, lets any
/// video start playing (muted), and records the media URLs the page requests. The best stream is
/// then handed to yt-dlp, which handles HLS/DASH manifests and direct files on its own.
@MainActor
final class PageSniffer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    struct Result {
        let mediaURL: URL
        /// True when `mediaURL` is an embedded player page (Vimeo, YouTube…) rather than a raw stream.
        let isEmbed: Bool
        let title: String?
        let thumbnail: URL?
        let userAgent: String?
    }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var found: [URL] = []
    private var embeds: [URL] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    private var settleTask: Task<Void, Never>?

    /// Hooks fetch/XHR and scans <video> elements and resource timings, in every frame.
    private static let hookScript = """
    (() => {
      const RX = /\\.(m3u8|mpd|mp4|m4v|webm|mov)(\\?|#|$)/i;
      const post = (u) => {
        try {
          if (!u) return;
          const abs = new URL(u, location.href).href;
          if (abs.startsWith('http') && RX.test(new URL(abs).pathname + (new URL(abs).search || '')))
            window.webkit.messageHandlers.pluck.postMessage(abs);
        } catch (e) {}
      };
      const f = window.fetch;
      if (f) window.fetch = function (input) { post(typeof input === 'string' ? input : input && input.url); return f.apply(this, arguments); };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) { post(url); return open.apply(this, arguments); };
      const EMBED = /^https:\\/\\/(player\\.vimeo\\.com\\/video|www\\.dailymotion\\.com\\/embed|geo\\.dailymotion\\.com\\/player|www\\.youtube(-nocookie)?\\.com\\/embed|player\\.twitch\\.tv|clips\\.twitch\\.tv\\/embed|w\\.soundcloud\\.com\\/player)/i;
      const scan = () => {
        document.querySelectorAll('iframe').forEach(f => {
          if (f.src && EMBED.test(f.src)) window.webkit.messageHandlers.pluck.postMessage({ embed: f.src });
        });
        document.querySelectorAll('video, audio, source').forEach(v => {
          const s = v.currentSrc || v.src;
          if (s && !s.startsWith('blob:')) post(s);
        });
        performance.getEntriesByType('resource').forEach(e => post(e.name));
      };
      const play = () => document.querySelectorAll('video').forEach(v => {
        v.muted = true;
        // Lazy players often keep the real source in a data attribute until scrolled into view.
        for (const k of ['src', 'videoSrc', 'video', 'mp4']) { if (v.dataset && v.dataset[k]) post(v.dataset[k]); }
        v.play().catch(() => {});
      });
      let ticks = 0;
      setInterval(() => {
        scan(); play();
        // Scroll down and back so lazy-loaded videos further down the page start loading.
        if (window.top === window && ++ticks < 12) window.scrollTo(0, (ticks % 6) * window.innerHeight);
      }, 800);
    })();
    """

    private static let metaScript = """
    JSON.stringify({
      title: (document.querySelector('meta[property="og:title"]') || {}).content || document.title || null,
      image: (document.querySelector('meta[property="og:image"]') || {}).content || null,
      ua: navigator.userAgent
    })
    """

    private static let adHosts = ["doubleclick", "googlesyndication", "googleads", "adservice", "imasdk", "adsystem", "advertising", "/ads/"]

    /// Looks for a playable stream on `url` for up to `timeout` seconds.
    func sniff(_ url: URL, timeout: TimeInterval = 20) async -> Result? {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(self, name: "pluck")

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        // WebKit pauses media and timers in views it thinks are hidden, so the page goes in an
        // on-screen window that's fully transparent, click-through and behind everything.
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: origin, size: frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.hasShadow = false
        window.contentView = webView
        window.orderBack(nil)
        self.webView = webView
        self.window = window

        webView.load(URLRequest(url: url))

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                await self.finish()
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let embed = (message.body as? [String: Any])?["embed"] as? String, let url = URL(string: embed) {
            if !embeds.contains(url) { embeds.append(url) }
            return
        }
        guard let string = message.body as? String, let url = URL(string: string),
              !found.contains(url),
              !Self.adHosts.contains(where: { string.localizedCaseInsensitiveContains($0) })
        else { return }
        found.append(url)
        // A manifest is the whole video; give the page a moment in case a better one follows.
        if Self.isManifest(url), settleTask == nil {
            settleTask = Task {
                try? await Task.sleep(for: .seconds(2))
                await self.finish()
            }
        }
    }

    private static func isManifest(_ url: URL) -> Bool {
        ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
    }

    private func finish() async {
        guard let continuation, let webView else { return }
        self.continuation = nil

        // Prefer a master playlist, then any manifest, then the first direct file.
        let manifests = found.filter(Self.isManifest)
        // Fall back to an embedded player, which yt-dlp has a dedicated extractor for.
        let stream = manifests.first { $0.lastPathComponent.localizedCaseInsensitiveContains("master") }
            ?? manifests.first
            ?? found.first
        let best = stream ?? embeds.first

        var title: String?, image: URL?, agent: String?
        if let json = try? await webView.evaluateJavaScript(Self.metaScript) as? String,
           let meta = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            title = (meta["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            image = (meta["image"] as? String).flatMap { URL(string: $0, relativeTo: webView.url) }
            agent = meta["ua"] as? String
        }

        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pluck")
        window?.orderOut(nil)
        window?.contentView = nil
        self.webView = nil
        self.window = nil

        continuation.resume(returning: best.map {
            Result(mediaURL: $0, isEmbed: stream == nil, title: title?.isEmpty == false ? title : nil, thumbnail: image, userAgent: agent)
        })
    }
}
