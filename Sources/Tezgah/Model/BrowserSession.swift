import AppKit
import Observation
import WebKit

/// A web page previewed in a tab, which both the user and Claude (through Tezgah's tools) drive.
@MainActor
@Observable
final class BrowserSession: NSObject, Identifiable {
    struct LogEntry: Identifiable, Equatable {
        enum Level: String { case log, info, warn, error, network }
        let id = UUID()
        let level: Level
        let message: String
        let date = Date()
    }

    /// A fixed page size, like a device, or nil to fill the tab.
    struct Viewport: Equatable, Hashable {
        let name: String
        let width: CGFloat
        let height: CGFloat

        static let presets: [Viewport] = [
            Viewport(name: "iPhone 16", width: 393, height: 852),
            Viewport(name: "iPhone SE", width: 375, height: 667),
            Viewport(name: "iPad", width: 820, height: 1180),
            Viewport(name: "Dizüstü", width: 1280, height: 800),
            Viewport(name: "Masaüstü", width: 1440, height: 900),
        ]
    }

    let id = UUID()
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var logs: [LogEntry] = []
    var viewport: Viewport?
    /// What Claude is doing in the page right now ("Tıklıyor: Kaydet"), shown over it.
    private(set) var claudeActivity: String?
    /// Logs Claude has already been given, so `browser_console` reports what is new.
    @ObservationIgnored private var logsReadByClaude = 0

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<String?, Never>] = []
    @ObservationIgnored private var activityClear: Task<Void, Never>?

    var errorCount: Int { logs.filter { $0.level == .error || $0.level == .network }.count }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController = controller
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled") // right-click › Inspect Element
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        super.init()
        controller.add(WeakMessageHandler(self), name: "tezgahConsole")
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        observations = [
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
    }

    // MARK: Navigation

    /// "localhost:3000", "example.com/x" and full URLs; local addresses get http, others https.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/"), FileManager.default.fileExists(atPath: text) { return URL(fileURLWithPath: text) }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) { return url }
        let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0") || text.hasPrefix("[::1]")
            || text.range(of: #"^\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil
        return URL(string: (isLocal ? "http://" : "https://") + text)
    }

    func open(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// Opens a page and waits until it has loaded; returns an error message if it did not.
    func openAndWait(_ url: URL, timeout: Duration = .seconds(20)) async -> String? {
        open(url)
        return await waitForLoad(timeout: timeout)
    }

    func waitForLoad(timeout: Duration = .seconds(20)) async -> String? {
        // A navigation may start a moment after a click; give it the chance.
        try? await Task.sleep(for: .milliseconds(120))
        guard webView.isLoading else { return nil }
        return await withCheckedContinuation { continuation in
            loadWaiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishWaiting("Sayfa \(timeout) içinde yüklenmedi")
            }
        }
    }

    private func finishWaiting(_ error: String?) {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume(returning: error) }
    }

    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func clearLogs() {
        logs = []
        logsReadByClaude = 0
    }

    /// Logs since Claude last asked.
    func takeNewLogsForClaude() -> [LogEntry] {
        let new = Array(logs.dropFirst(min(logsReadByClaude, logs.count)))
        logsReadByClaude = logs.count
        return new
    }

    func showActivity(_ text: String) {
        claudeActivity = text
        activityClear?.cancel()
        activityClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.claudeActivity = nil
        }
    }

    private func log(_ level: LogEntry.Level, _ message: String) {
        logs.append(LogEntry(level: level, message: message))
        let overflow = logs.count - 500
        if overflow > 0 {
            logs.removeFirst(overflow)
            logsReadByClaude = max(0, logsReadByClaude - overflow)
        }
    }

    // MARK: Page access for tools

    /// Runs JavaScript as the body of an async function and returns its result as JSON text.
    func evaluate(_ body: String) async throws -> String {
        let script = "return JSON.stringify(await (async () => { \(body) })(), null, 1) ?? 'undefined';"
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page)
        return result as? String ?? "undefined"
    }

    /// The page as a PNG at CSS-pixel scale, so coordinates in it are what `browser_click` takes.
    func screenshot(fullPage: Bool = false) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        let width = webView.bounds.width
        if fullPage, let height = try? await webView.evaluateJavaScript("document.documentElement.scrollHeight") as? Double {
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: min(CGFloat(height), 8000))
        }
        configuration.snapshotWidth = NSNumber(value: Double(width))
        let image = try await webView.takeSnapshot(configuration: configuration)
        return Self.png(image, width: width)
    }

    private static func png(_ image: NSImage, width: CGFloat) -> Data {
        // Draw at one pixel per point: a 2x screen would otherwise double every coordinate.
        let scale = min(1, 1600 / max(width, 1))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return Data() }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    /// Catches console output, uncaught errors and failed requests, and draws Claude's clicks.
    private static let bridgeScript = #"""
    (() => {
      if (window.__tezgah) return;
      window.__tezgah = true;
      const post = (level, args) => {
        try {
          const text = Array.from(args).map(a => {
            if (a instanceof Error) return a.stack || a.message;
            if (typeof a === 'object') { try { return JSON.stringify(a); } catch { return String(a); } }
            return String(a);
          }).join(' ');
          window.webkit.messageHandlers.tezgahConsole.postMessage({ level, text: text.slice(0, 4000) });
        } catch {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) { post(level === 'debug' ? 'log' : level, args); return original.apply(this, args); };
      }
      addEventListener('error', e => post('error', [e.message + (e.filename ? ` (${e.filename}:${e.lineno})` : '')]));
      addEventListener('unhandledrejection', e => post('error', ['Unhandled rejection: ' + (e.reason && (e.reason.stack || e.reason.message) || e.reason)]));
      const originalFetch = window.fetch;
      if (originalFetch) window.fetch = async (...args) => {
        try {
          const response = await originalFetch(...args);
          if (!response.ok) post('network', [`${response.status} ${response.statusText} ← ${response.url}`]);
          return response;
        } catch (error) {
          post('network', [`İstek başarısız: ${args[0]} (${error.message})`]);
          throw error;
        }
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url, ...rest) {
        this.addEventListener('loadend', () => { if (this.status === 0 || this.status >= 400) post('network', [`${this.status || 'başarısız'} ← ${method} ${url}`]); });
        return open.call(this, method, url, ...rest);
      };
      window.__tezgahRipple = (x, y) => {
        const dot = document.createElement('div');
        dot.style.cssText = `position:fixed;left:${x - 14}px;top:${y - 14}px;width:28px;height:28px;border-radius:50%;` +
          'border:2.5px solid #D97757;background:rgba(217,119,87,.25);z-index:2147483647;pointer-events:none;' +
          'transition:transform .5s ease-out,opacity .5s ease-out;transform:scale(.6);opacity:1';
        document.documentElement.appendChild(dot);
        requestAnimationFrame(() => { dot.style.transform = 'scale(1.6)'; dot.style.opacity = '0'; });
        setTimeout(() => dot.remove(), 600);
      };
    })();
    """#
}

extension BrowserSession: WKNavigationDelegate, WKScriptMessageHandler {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishWaiting(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    private func failed(_ error: any Error) {
        let nsError = error as NSError
        // A new navigation replacing this one is not a failure.
        guard nsError.code != NSURLErrorCancelled else { return }
        let message = "Sayfa yüklenemedi: \(nsError.localizedDescription)"
        log(.network, message)
        finishWaiting(message)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
            log(LogEntry.Level(rawValue: body["level"] as? String ?? "") ?? .log, text)
        }
    }
}

/// Keeps WebKit's strong reference to message handlers from keeping the session alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
