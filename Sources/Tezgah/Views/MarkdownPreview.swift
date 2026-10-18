import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import cmark_gfm
import cmark_gfm_extensions

/// GitHub-flavored Markdown to HTML: tables, task lists, strikethrough, autolinks, footnotes.
enum MarkdownRenderer {
    static func html(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        // Raw HTML (<img>, <details>…) is kept like on GitHub; "tagfilter" disarms <script>, <iframe> and
        // friends, and the page's content security policy blocks scripts anyway.
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            if let syntax = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntax)
            }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }
}

/// Serves files under one folder to the preview as tezgah-file:///absolute/path, so relative
/// images work without giving the page access to the whole disk.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "tezgah-file"
    let rootPath: String

    init(root: URL) {
        rootPath = FileWatcher.realPath(root.path)
    }

    static func url(for fileURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = fileURL.path + (fileURL.hasDirectoryPath ? "/" : "")
        return components.url
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = FileWatcher.realPath(url.path)
        guard path == rootPath || path.hasPrefix(rootPath + "/"),
              let data = FileManager.default.contents(atPath: path) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

struct MarkdownPreview: NSViewRepresentable {
    let document: EditorDocument
    /// The text version shown; passing it makes SwiftUI update the view on every edit.
    let version: Int
    /// Folder the preview may read images from.
    let root: URL
    let openFile: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openFile: openFile)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(root: root), forURLScheme: LocalFileSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // no white flash in dark mode
        context.coordinator.load(document, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.openFile = openFile
        context.coordinator.update(document, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var openFile: (URL) -> Void
        private var renderedVersion = -1
        private var isLoaded = false
        private var pendingUpdate: Task<Void, Never>?

        init(openFile: @escaping (URL) -> Void) {
            self.openFile = openFile
        }

        func load(_ document: EditorDocument, into webView: WKWebView) {
            renderedVersion = document.textVersion
            let base = LocalFileSchemeHandler.url(for: document.url.deletingLastPathComponent())
            webView.loadHTMLString(Self.page(body: MarkdownRenderer.html(document.text), base: base), baseURL: base)
        }

        /// Re-renders after typing pauses, swapping the content in place so the scroll position stays.
        func update(_ document: EditorDocument, in webView: WKWebView) {
            guard document.textVersion != renderedVersion else { return }
            pendingUpdate?.cancel()
            pendingUpdate = Task { [weak self, weak webView, weak document] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, let webView, let document, self.isLoaded else { return }
                self.renderedVersion = document.textVersion
                let html = MarkdownRenderer.html(document.text)
                guard let json = try? String(data: JSONEncoder().encode(html), encoding: .utf8) else { return }
                _ = try? await webView.evaluateJavaScript("update(\(json))")
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { isLoaded = true }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                guard action.navigationType == .linkActivated, let url = action.request.url else {
                    decisionHandler(.allow)
                    return
                }
                // Jumps within the page.
                if url.fragment != nil, url.path == webView.url?.path || url.path.isEmpty {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                if url.scheme == LocalFileSchemeHandler.scheme {
                    openFile(URL(fileURLWithPath: url.path))
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        static func page(body: String, base: URL?) -> String {
            let nonce = UUID().uuidString
            return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(LocalFileSchemeHandler.scheme): https: http: data:; media-src \(LocalFileSchemeHandler.scheme): https:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'">
            \(base.map { "<base href=\"\($0.absoluteString)\">" } ?? "")
            <style>\(css)</style>
            </head><body><article id="content">\(body)</article>
            <script nonce="\(nonce)">function update(html) { document.getElementById('content').innerHTML = html; }</script>
            </body></html>
            """
        }

        static let css = """
        :root { color-scheme: light dark; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code-bg: #f6f8fa; --link: #0969da; }
        @media (prefers-color-scheme: dark) { :root { --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --code-bg: #262c36; --link: #4493f8; } }
        html { background: transparent; }
        body { margin: 0; color: var(--fg); font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; }
        article { max-width: 880px; margin: 0 auto; padding: 24px 32px 64px; word-wrap: break-word; }
        h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
        h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 .6em; line-height: 1.25; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre { font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
        code { background: var(--code-bg); padding: .15em .35em; border-radius: 6px; }
        pre { background: var(--code-bg); padding: 14px 16px; border-radius: 8px; overflow: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { border: 1px solid var(--border); padding: 6px 13px; }
        th { font-weight: 600; } tr:nth-child(2n) { background: var(--code-bg); }
        img { max-width: 100%; }
        hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
        ul.contains-task-list, li.task-list-item { list-style: none; }
        li.task-list-item input { margin: 0 .4em 0 -1.4em; }
        .footnotes { font-size: 13px; color: var(--muted); }
        """
    }
}
