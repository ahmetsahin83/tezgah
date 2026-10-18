import AppKit
import CodeEditSourceEditor
import SwiftUI
import WebKit

/// The conversation of a Claude session, rendered from its transcript.
struct ClaudeConversationView: NSViewRepresentable {
    struct Status: Equatable {
        enum Mode: String {
            case starting, idle, working, waiting, finished, ended
        }

        var mode: Mode
        var text: String?
        /// When the current turn started, for the elapsed time.
        var since: Date?
    }

    let entries: [ClaudeTranscriptEntry]
    var subagents: [String: [ClaudeTranscriptEntry]] = [:]
    var runningAgents: Set<String> = []
    let version: Int
    let context: ClaudeConversationRenderer.Context
    let status: Status
    let root: URL
    let projectName: String
    /// Whose conversation it is, for the few words the page says itself.
    var provider = AgentProvider.claude
    let controller: ClaudeConversationController
    let actions: Actions

    struct Actions {
        var openFile: (URL, Int?) -> Void
        var openSessionDiff: (String) -> Void
        /// Runs a shell command from the conversation in a terminal.
        var runInTerminal: (String) -> Void
        /// "Düzenle" on a prompt: its text goes back into the composer.
        var editPrompt: (String) -> Void
        /// "Tekrar gönder" on a prompt.
        var resendPrompt: (String) -> Void
        /// A key typed while the conversation has focus; it belongs in the composer.
        var typeAhead: (String) -> Void
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(root: root)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakScriptHandler(context.coordinator), name: "tezgah")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        context.coordinator.actions = actions
        context.coordinator.load(into: webView, projectName: projectName, agentName: provider.displayName)
        controller.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = actions
        coordinator.runningAgents = runningAgents
        coordinator.update(entries: entries, subagents: subagents, version: version, context: self.context, status: status)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tezgah")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var actions: Actions?
        var runningAgents: Set<String> = []
        private let renderer: ClaudeConversationRenderer
        private weak var webView: WKWebView?
        private var isLoaded = false
        private var sentHTML: [String: String] = [:]
        private var sentOrder: [String] = []
        private var sentStatus: Status?
        private var renderedKey: (version: Int, context: ClaudeConversationRenderer.Context)?
        private var latest: (entries: [ClaudeTranscriptEntry], subagents: [String: [ClaudeTranscriptEntry]], version: Int, context: ClaudeConversationRenderer.Context, status: Status)?
        private var hasRenderedOnce = false
        private var projectName = ""
        private var agentName = "Claude"

        init(root: URL) {
            renderer = ClaudeConversationRenderer(root: root)
        }

        func load(into webView: WKWebView, projectName: String, agentName: String) {
            self.agentName = agentName
            self.webView = webView
            self.projectName = projectName
            #if DEBUG
            Self.debugWebViews.append(Weak(webView))
            #endif
            webView.loadHTMLString(Self.page(projectName: projectName, agentName: agentName), baseURL: nil)
        }

        func update(entries: [ClaudeTranscriptEntry], subagents: [String: [ClaudeTranscriptEntry]], version: Int, context: ClaudeConversationRenderer.Context, status: Status) {
            latest = (entries, subagents, version, context, status)
            guard isLoaded, let webView else { return }

            if renderedKey?.version != version || renderedKey?.context != context {
                renderedKey = (version, context)
                let blocks = renderer.blocks(for: entries, subagents: subagents, runningAgents: runningAgents, context: context)
                var changed: [[String: String]] = []
                for block in blocks where sentHTML[block.id] != block.html {
                    changed.append(["id": block.id, "html": block.html])
                    sentHTML[block.id] = block.html
                }
                let order = blocks.map(\.id)
                if !changed.isEmpty || order != sentOrder || !hasRenderedOnce {
                    let ids = Set(order)
                    sentHTML = sentHTML.filter { ids.contains($0.key) }
                    sentOrder = order
                    let payload: [String: Any] = ["blocks": changed, "order": order, "initial": !hasRenderedOnce]
                    hasRenderedOnce = true
                    call("apply", payload, in: webView)
                }
            }

            if status != sentStatus {
                sentStatus = status
                var payload: [String: Any] = ["mode": status.mode.rawValue]
                if let text = status.text { payload["text"] = text }
                if let since = status.since { payload["since"] = since.timeIntervalSince1970 * 1000 }
                call("setStatus", payload, in: webView)
            }
        }

        private func call(_ function: String, _ payload: [String: Any], in webView: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("\(function)(\(json))", completionHandler: nil)
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                isLoaded = true
                if let latest {
                    update(entries: latest.entries, subagents: latest.subagents, version: latest.version, context: latest.context, status: latest.status)
                }
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                // Only the page itself loads here; links come through the script handler.
                if action.navigationType == .linkActivated, let url = action.request.url {
                    decisionHandler(.cancel)
                    open(url)
                } else {
                    decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
                }
            }
        }

        /// WebKit's page process went away (memory pressure, a crash): load the page again and
        /// re-send everything, rather than leaving the conversation blank.
        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated {
                isLoaded = false
                hasRenderedOnce = false
                sentHTML = [:]
                sentOrder = []
                sentStatus = nil
                renderedKey = nil
                webView.loadHTMLString(Self.page(projectName: projectName, agentName: agentName), baseURL: nil)
            }
        }

        private func open(_ url: URL) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let path = items.first { $0.name == "path" }?.value
            switch url.scheme {
            case "tezgah-open":
                if let path {
                    actions?.openFile(URL(fileURLWithPath: path), items.first { $0.name == "line" }?.value.flatMap(Int.init))
                }
            case "tezgah-diff":
                if let path { actions?.openSessionDiff(path) }
            case "tezgah-run":
                if let text = items.first(where: { $0.name == "text" })?.value { actions?.runInTerminal(text) }
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            default:
                break
            }
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any] else { return }
                if let link = body["open"] as? String, let url = URL(string: link) {
                    open(url)
                } else if let command = body["run"] as? String {
                    actions?.runInTerminal(command)
                } else if let text = body["copy"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } else if let key = body["type"] as? String {
                    actions?.typeAhead(key)
                } else if let id = body["entry"] as? String, let action = body["action"] as? String {
                    entryAction(action, id: id)
                }
            }
        }

        private func entryAction(_ action: String, id: String) {
            guard let entry = latest?.entries.first(where: { $0.id == id }) else { return }
            let text: String
            switch entry.kind {
            case .prompt(let prompt, _): text = prompt
            case .reply(let markdown): text = markdown
            default: return
            }
            switch action {
            case "copy":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "edit": actions?.editPrompt(text)
            case "resend": actions?.resendPrompt(text)
            default: break
            }
        }

        #if DEBUG
        struct Weak { weak var webView: WKWebView?; init(_ webView: WKWebView) { self.webView = webView } }
        /// For DebugAutomation's `js` command.
        static var debugWebViews: [Weak] = []
        #endif

        static func page(projectName: String, agentName: String) -> String {
            let agent = (try? JSONSerialization.data(withJSONObject: [agentName])).flatMap { String(data: $0, encoding: .utf8) } ?? #"["Claude"]"#
            let nonce = UUID().uuidString
            return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'">
            <style>\(css)</style>
            </head><body class="empty">
            <main>
              <section id="welcome">
                <div class="mark">\(Icon.sparkle)</div>
                <h1>Ne üzerinde çalışalım?</h1>
                <p>\(ClaudeConversationRenderer.escape(projectName))</p>
                <div class="hints"><span><kbd>@</kbd> dosya ekle</span><span><kbd>/</kbd> komutlar</span><span><kbd>⇧</kbd><kbd>↩</kbd> yeni satır</span></div>
              </section>
              <div id="log"></div>
              <div id="status"></div>
            </main>
            <script nonce="\(nonce)">const agentName = \(agent)[0];\(script)</script>
            </body></html>
            """
        }

        static var css: String {
            func hex(_ color: NSColor) -> String {
                let rgb = color.usingColorSpace(.sRGB) ?? color
                return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
            }
            func syntax(_ theme: EditorTheme) -> String {
                let pairs: [(String, EditorTheme.Attribute)] = [
                    ("k", theme.keywords), ("c", theme.comments), ("v", theme.variables), ("n", theme.numbers),
                    ("s", theme.strings), ("t", theme.types), ("a", theme.attributes),
                ]
                return pairs.map { name, attribute in
                    "--syn-\(name): \(hex(attribute.color)); --syn-\(name)-weight: \(attribute.bold ? 600 : 400); --syn-\(name)-style: \(attribute.italic ? "italic" : "normal");"
                }.joined(separator: " ")
            }
            return """
            :root { \(syntax(EditorThemes.light)) }
            @media (prefers-color-scheme: dark) { :root { \(syntax(EditorThemes.dark)) } }
            \(staticCSS)
            """
        }

        static let staticCSS = """
        :root {
          color-scheme: light dark;
          --fg: #1d1d1f; --fg2: #3a3a3f; --muted: #6e6e73; --faint: #a0a0a6;
          --line: rgba(0,0,0,.075); --line2: rgba(0,0,0,.12);
          --surface: rgba(0,0,0,.032); --surface2: rgba(0,0,0,.055); --hover: rgba(0,0,0,.04);
          --bubble: #f2f0ea; --code-bg: #f7f7f5;
          --accent: #d97757; --accent-soft: rgba(217,119,87,.12);
          --link: #0a64d6;
          --add-bg: rgba(52,168,83,.11); --add-fg: #1a7f37; --del-bg: rgba(234,67,53,.09); --del-fg: #c62828;
          --warn: #b45f06; --warn-bg: rgba(255,149,0,.13); --bad: #c62828; --bad-bg: rgba(255,59,48,.09);
          --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --fg: #ececee; --fg2: #cfcfd4; --muted: #9a9aa2; --faint: #6b6b73;
            --line: rgba(255,255,255,.075); --line2: rgba(255,255,255,.12);
            --surface: rgba(255,255,255,.035); --surface2: rgba(255,255,255,.06); --hover: rgba(255,255,255,.045);
            --bubble: #2c2c33; --code-bg: #26262c;
            --accent: #e08a6b; --accent-soft: rgba(224,138,107,.14);
            --link: #5aa2ff;
            --add-bg: rgba(63,185,80,.13); --add-fg: #56d364; --del-bg: rgba(248,81,73,.12); --del-fg: #ff7b72;
            --warn: #ffb340; --warn-bg: rgba(255,179,64,.12); --bad: #ff6b61; --bad-bg: rgba(255,69,58,.12);
          }
        }
        * { box-sizing: border-box; }
        html { background: transparent; -webkit-text-size-adjust: none; }
        body { margin: 0; color: var(--fg); font: 14px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
               -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
        main { max-width: 800px; margin: 0 auto; padding: 22px 28px 28px; }
        ::selection { background: rgba(10,100,214,.22); }

        /* Welcome */
        #welcome { display: none; text-align: center; padding-top: 14vh; color: var(--muted); animation: fade .4s ease both; }
        body.empty #welcome { display: block; }
        #welcome .mark { color: var(--accent); display: inline-flex; padding: 14px; border-radius: 18px; background: var(--accent-soft); }
        #welcome .mark svg { width: 26px; height: 26px; }
        #welcome h1 { color: var(--fg); font-size: 21px; font-weight: 600; letter-spacing: -.01em; margin: 18px 0 4px; }
        #welcome p { margin: 0 0 22px; font-size: 13px; }
        .hints { display: inline-flex; gap: 18px; font-size: 12px; color: var(--faint); }
        kbd { font: 11px var(--mono); border: 1px solid var(--line2); border-bottom-width: 2px; border-radius: 5px; padding: 0 5px; margin-right: 3px; color: var(--muted); }

        /* Blocks */
        .block.enter { animation: rise .28s cubic-bezier(.2,.7,.3,1) both; }
        @keyframes rise { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
        @keyframes fade { from { opacity: 0; } to { opacity: 1; } }

        .prompt { display: flex; justify-content: flex-end; margin: 26px 0 14px; }
        .block:first-child .prompt { margin-top: 4px; }
        .bubble { max-width: 84%; background: var(--bubble); border-radius: 16px 16px 5px 16px; padding: 9px 14px; }
        .prompt-text { white-space: pre-wrap; overflow-wrap: anywhere; }
        .prompt-text.clamped { max-height: 15.5em; overflow: hidden; -webkit-mask-image: linear-gradient(#000 70%, transparent); }
        .more { display: block; margin: 4px 0 0 auto; }
        .chips { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 6px; }
        .chip { display: inline-flex; align-items: center; gap: 5px; font-size: 12px; color: var(--muted); background: var(--surface2); border-radius: 7px; padding: 2px 8px; }

        .command { display: flex; justify-content: flex-end; align-items: baseline; gap: 8px; margin: 22px 0 8px; font: 12.5px var(--mono); }
        .command .slash { color: var(--accent); background: var(--accent-soft); padding: 2px 8px; border-radius: 7px; }
        .command .args { color: var(--muted); }
        .command-output { margin: 0 0 12px auto; max-width: 84%; font: 11.5px/1.5 var(--mono); color: var(--muted); white-space: pre-wrap; background: var(--surface); border-radius: 8px; padding: 8px 10px; }

        .reply { margin: 8px 0 10px; overflow-wrap: break-word; }
        .reply > :first-child, .sub-result > :first-child, .plan-body > :first-child { margin-top: 0; }
        .reply > :last-child, .sub-result > :last-child, .plan-body > :last-child { margin-bottom: 0; }
        .reply p, .sub-result p, .plan-body p { margin: 0 0 .7em; }
        .reply h1, .reply h2, .reply h3, .reply h4, .plan-body h1, .plan-body h2, .plan-body h3 { line-height: 1.3; margin: 1.15em 0 .45em; letter-spacing: -.005em; }
        .reply h1, .plan-body h1 { font-size: 1.3em; } .reply h2, .plan-body h2 { font-size: 1.16em; } .reply h3, .reply h4, .plan-body h3 { font-size: 1.02em; }
        .reply ul, .reply ol, .plan-body ul, .plan-body ol, .sub-result ul, .sub-result ol { margin: 0 0 .7em; padding-left: 1.4em; }
        .reply li, .plan-body li { margin: .18em 0; }
        .reply li::marker { color: var(--faint); }
        .reply blockquote { margin: .6em 0; padding: 0 0 0 12px; border-left: 3px solid var(--line2); color: var(--muted); }
        .reply hr { border: 0; border-top: 1px solid var(--line); margin: 1.2em 0; }
        .reply table, .plan-body table { border-collapse: collapse; margin: .6em 0 .9em; font-size: 13px; display: block; overflow-x: auto; }
        .reply th, .reply td, .plan-body th, .plan-body td { border: 1px solid var(--line2); padding: 5px 11px; text-align: left; }
        .reply th, .plan-body th { background: var(--surface); font-weight: 600; }
        a { color: var(--link); text-decoration: none; cursor: pointer; }
        a:hover { text-decoration: underline; }
        code { font: 12.5px var(--mono); background: var(--surface2); padding: .12em .36em; border-radius: 5px; }
        a.file code { color: var(--link); }
        strong { font-weight: 600; }

        .codeblock { border: 1px solid var(--line); background: var(--code-bg); border-radius: 10px; margin: .7em 0 .9em; overflow: hidden; }
        .codebar { display: flex; align-items: center; justify-content: space-between; height: 28px; padding: 0 6px 0 12px; border-bottom: 1px solid var(--line); font-size: 11px; color: var(--faint); }
        .codebar .lang { text-transform: lowercase; }
        .codeblock pre { margin: 0; padding: 10px 14px 12px; overflow-x: auto; }
        .codeblock code { background: none; padding: 0; font-size: 12px; line-height: 1.55; display: block; white-space: pre; }
        button.copy, button.more { all: unset; font: 11px -apple-system; color: var(--muted); padding: 2px 8px; border-radius: 6px; cursor: default; margin-left: auto; }
        button.copy:hover, button.more:hover { background: var(--surface2); color: var(--fg); }
        .bar-actions { display: flex; align-items: center; gap: 2px; margin-left: auto; }
        .bar-actions button.copy { margin-left: 0; }
        button.run, a.action.run { display: inline-flex; align-items: center; gap: 4px; }
        button.run:hover, .meta a.action.run:hover { color: var(--accent); }
        /* Run buttons appear on hover, so long command lists stay calm. */
        .tool .row a.action.run { opacity: 0; transition: opacity .12s ease; }
        .tool:hover > .row a.action.run, .tool[open] > .row a.action.run { opacity: 1; }

        .k { color: var(--syn-k); font-weight: var(--syn-k-weight); } .c { color: var(--syn-c); font-style: var(--syn-c-style); }
        .v { color: var(--syn-v); } .n { color: var(--syn-n); } .s { color: var(--syn-s); } .t { color: var(--syn-t); } .a { color: var(--syn-a); }

        /* Message actions, on hover */
        .prompt { flex-wrap: wrap; }
        .msg-actions { display: flex; gap: 2px; opacity: 0; transition: opacity .12s ease; height: 24px; margin-top: 2px; }
        .prompt .msg-actions { flex-basis: 100%; justify-content: flex-end; }
        .reply .msg-actions { margin-top: -2px; }
        .prompt:hover .msg-actions, .reply:hover .msg-actions { opacity: 1; }
        .msg-actions button { all: unset; display: flex; align-items: center; justify-content: center; width: 24px; height: 22px;
                              border-radius: 6px; color: var(--faint); cursor: default; }
        .msg-actions button:hover { background: var(--surface2); color: var(--fg); }
        .msg-actions button.done { color: var(--add-fg); }
        .msg-actions svg { width: 13px; height: 13px; }

        /* Find */
        mark.find { background: rgba(255, 196, 0, .32); color: inherit; border-radius: 3px; padding: 0 1px; margin: 0 -1px; }
        mark.find.current { background: rgba(255, 149, 0, .75); box-shadow: 0 0 0 2px rgba(255, 149, 0, .35); }

        /* Tools */
        .tool { margin: 1px 0; border-radius: 8px; }
        .tool .row { display: flex; align-items: center; gap: 8px; min-height: 28px; padding: 3px 8px; margin: 0 -8px;
                     font-size: 12.5px; color: var(--muted); border-radius: 8px; -webkit-user-select: none; user-select: none; }
        details > summary { list-style: none; cursor: default; }
        details > summary::-webkit-details-marker { display: none; }
        details > summary:hover { background: var(--hover); }
        .tool .icon { display: flex; color: var(--faint); flex: none; }
        .verb { color: var(--fg2); font-weight: 560; flex: none; }
        .target { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .target code { background: none; padding: 0; font-size: 11.5px; color: var(--muted); }
        .target .folder { margin-left: 6px; }
        .meta { display: flex; align-items: center; gap: 8px; flex: none; font-size: 11.5px; font-variant-numeric: tabular-nums; }
        .meta .action { font-size: 11px; color: var(--muted); padding: 1px 7px; border-radius: 6px; background: var(--surface2); -webkit-user-select: none; }
        .meta .action:hover { color: var(--fg); text-decoration: none; }
        .dim { color: var(--faint); }
        .added { color: var(--add-fg); } .removed { color: var(--del-fg); }
        .chev { display: flex; color: var(--faint); transition: transform .16s ease; flex: none; }
        .chev svg { width: 11px; height: 11px; }
        details[open] > summary .chev { transform: rotate(90deg); }
        .tool-body { margin: 3px 0 10px 22px; }
        .tool.failed .verb { color: var(--bad); }
        .tool.waiting > .row { background: var(--warn-bg); }
        .tag { font-size: 10.5px; padding: 1px 7px; border-radius: 999px; background: var(--surface2); color: var(--muted); }
        .pill { font-size: 10.5px; font-weight: 550; padding: 1px 8px; border-radius: 999px; background: var(--surface2); color: var(--muted); }
        .pill.warn { background: var(--warn-bg); color: var(--warn); }
        .pill.bad { background: var(--bad-bg); color: var(--bad); }

        .explored { margin: 1px 0; }
        .explored > summary { display: flex; align-items: center; gap: 8px; min-height: 28px; padding: 3px 8px; margin: 0 -8px;
                              font-size: 12.5px; color: var(--muted); border-radius: 8px; -webkit-user-select: none; }
        .explored > summary > svg { color: var(--faint); flex: none; }
        .explored-list { margin: 2px 0 6px 6px; padding-left: 14px; border-left: 1px solid var(--line2); }

        .console, .diff, pre.output { border: 1px solid var(--line); background: var(--code-bg); border-radius: 9px; }
        .console { overflow: hidden; }
        .console pre { margin: 0; padding: 7px 12px; font: 11.5px/1.55 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; }
        .console .command-line { color: var(--fg); }
        .console .output { border: 0; border-top: 1px solid var(--line); border-radius: 0; color: var(--fg2); max-height: 340px; overflow: auto; }
        .prompt-sign { color: var(--accent); -webkit-user-select: none; }
        pre.output { margin: 0; padding: 7px 12px; font: 11.5px/1.55 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; color: var(--fg2); max-height: 340px; overflow: auto; }
        pre.output + pre.output, pre.output + .diff, .diff + pre.output { margin-top: 6px; }
        .error-text { color: var(--bad) !important; background: var(--bad-bg) !important; }

        .diff { overflow: auto; max-height: 460px; }
        .diff + .diff { margin-top: 6px; }
        .diff table { border-collapse: collapse; min-width: 100%; font: 11.5px/1.6 var(--mono); }
        .diff td { padding: 0; vertical-align: top; }
        .diff td.ln { width: 1%; min-width: 34px; padding: 0 6px; text-align: right; color: var(--faint); -webkit-user-select: none; white-space: nowrap; }
        .diff td.code { white-space: pre; padding: 0 14px 0 8px; }
        .diff tr:first-child td { padding-top: 5px; } .diff tr:last-child td { padding-bottom: 5px; }
        .diff tr.add { background: var(--add-bg); } .diff tr.del { background: var(--del-bg); }
        .diff tr.add td.ln { color: var(--add-fg); } .diff tr.del td.ln { color: var(--del-fg); }
        .diff tr.gap td { height: 6px; background: var(--surface2); padding: 0; }

        .todos, .plan { border: 1px solid var(--line); border-radius: 12px; padding: 10px 14px 11px; margin: 10px 0; background: var(--surface); }
        .todos-head, .plan-head { display: flex; align-items: center; gap: 8px; font-size: 12px; font-weight: 600; color: var(--fg2); margin-bottom: 6px; }
        .todos-head svg, .plan-head svg { color: var(--faint); }
        .todos-head .dim { margin-left: auto; font-weight: 500; font-variant-numeric: tabular-nums; }
        .plan-head .pill { margin-left: auto; }
        .todo { display: flex; align-items: flex-start; gap: 9px; font-size: 13px; padding: 2px 0; }
        .todo .mark { display: flex; padding-top: 3px; color: var(--faint); flex: none; }
        .todo.completed { color: var(--faint); } .todo.completed span:last-child { text-decoration: line-through; text-decoration-color: var(--line2); }
        .todo.completed .mark { color: var(--add-fg); }
        .todo.in_progress { color: var(--fg); font-weight: 550; }
        .plan-body { font-size: 13.5px; }

        .question { margin: 2px 0 6px; } .question .q { font-weight: 550; color: var(--fg); margin-bottom: 4px; font-size: 13px; }
        .option { display: flex; align-items: baseline; gap: 8px; font-size: 13px; color: var(--muted); padding: 1px 0; }
        .option .dot { width: 7px; height: 7px; border-radius: 50%; border: 1.5px solid var(--faint); flex: none; transform: translateY(-1px); }
        .option.chosen { color: var(--fg); font-weight: 550; } .option.chosen .dot { background: var(--accent); border-color: var(--accent); }
        .option .dim { font-weight: 400; font-size: 12px; }

        .sub-label { font-size: 10.5px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; color: var(--faint); margin: 6px 0 3px; }
        .sub-prompt { white-space: pre-wrap; font-size: 12.5px; color: var(--muted); background: var(--surface); border-radius: 8px; padding: 7px 10px; }
        .sub-result { font-size: 13px; }
        .sub-steps { margin: 2px 0 4px; padding-left: 12px; border-left: 2px solid var(--accent-soft); }
        .sub-steps .tool .row { min-height: 24px; font-size: 12px; }
        .sub-steps .tool-body { margin-left: 18px; }
        .sub-note { font-size: 12px; color: var(--muted); margin: 3px 0; white-space: pre-wrap; }
        .sub-more { font-size: 11.5px; margin: 2px 0 4px; }

        .notice { display: flex; align-items: center; gap: 12px; margin: 16px 0; font-size: 11.5px; color: var(--faint); }
        .notice::before, .notice::after { content: ""; flex: 1; height: 1px; background: var(--line); }
        .turn-end { display: flex; align-items: center; gap: 6px; margin: 4px 0 20px; font-size: 11px; color: var(--faint); font-variant-numeric: tabular-nums; }
        .turn-end svg { color: var(--accent); opacity: .7; }

        /* Live status */
        #status { min-height: 28px; display: flex; align-items: center; gap: 9px; margin-top: 6px; font-size: 12.5px; color: var(--muted); }
        #status:empty { display: none; }
        #status .spark { color: var(--accent); display: flex; animation: spin 2.4s linear infinite; }
        #status .shimmer { background: linear-gradient(90deg, var(--muted) 0%, var(--muted) 40%, var(--fg) 50%, var(--muted) 60%, var(--muted) 100%);
                           background-size: 250% 100%; -webkit-background-clip: text; color: transparent; animation: shimmer 2.2s linear infinite; font-weight: 550; }
        #status .step { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--faint); }
        #status .elapsed { color: var(--faint); font-variant-numeric: tabular-nums; flex: none; }
        #status.waiting .label { color: var(--warn); font-weight: 550; }
        .spinner { width: 11px; height: 11px; border-radius: 50%; border: 1.6px solid var(--line2); border-top-color: var(--accent); animation: spin .8s linear infinite; flex: none; }
        .spinner.small { width: 10px; height: 10px; }
        @keyframes spin { to { transform: rotate(360deg); } }
        @keyframes shimmer { from { background-position: 100% 0; } to { background-position: -150% 0; } }
        @media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } #status .shimmer { color: var(--muted); } }
        """

        static let script = #"""
        const log = document.getElementById('log');
        const statusEl = document.getElementById('status');
        const userOpen = new Map();
        let stick = true;
        let statusTimer = null;

        function nearBottom() {
          const s = document.scrollingElement;
          return s.scrollHeight - s.scrollTop - s.clientHeight < 80;
        }
        addEventListener('scroll', () => { stick = nearBottom(); }, { passive: true });
        function toBottom(smooth) {
          const s = document.scrollingElement;
          s.scrollTo({ top: s.scrollHeight, behavior: smooth ? 'smooth' : 'auto' });
        }
        new ResizeObserver(() => { if (stick) toBottom(false); }).observe(document.body);

        function apply(p) {
          const follow = stick || nearBottom();
          const nodes = new Map();
          for (const n of log.children) nodes.set(n.dataset.id, n);
          for (const b of p.blocks) {
            let n = nodes.get(b.id);
            if (!n) {
              n = document.createElement('div');
              n.className = 'block' + (p.initial ? '' : ' enter');
              n.dataset.id = b.id;
              nodes.set(b.id, n);
            }
            n.innerHTML = b.html;
            for (const d of n.querySelectorAll('details[data-key]')) {
              if (userOpen.has(d.dataset.key)) d.open = userOpen.get(d.dataset.key);
            }
          }
          let prev = null;
          for (const id of p.order) {
            const n = nodes.get(id);
            if (!n) continue;
            const expected = prev ? prev.nextSibling : log.firstChild;
            if (n !== expected) log.insertBefore(n, expected);
            prev = n;
          }
          const keep = new Set(p.order);
          for (const [id, n] of nodes) if (!keep.has(id)) n.remove();
          document.body.classList.toggle('empty', p.order.length === 0 && !statusEl.dataset.busy);
          if (findQuery) { highlight(findQuery); }
          if (follow && !findQuery) { stick = true; toBottom(!p.initial); }
        }

        // Find in conversation (⌘F). Matches are wrapped in <mark>; folded rows open to show the current one.
        let findQuery = '';
        let findIndex = 0;
        function clearMarks() {
          for (const m of log.querySelectorAll('mark.find')) {
            const parent = m.parentNode;
            parent.replaceChild(document.createTextNode(m.textContent), m);
            parent.normalize();
          }
        }
        function highlight(query) {
          clearMarks();
          if (!query) return 0;
          const needle = query.toLocaleLowerCase('tr');
          const walker = document.createTreeWalker(log, NodeFilter.SHOW_TEXT, {
            acceptNode: n => n.parentElement.closest('svg, button, .msg-actions') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
          });
          const nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          for (const node of nodes) {
            const text = node.nodeValue;
            const lower = text.toLocaleLowerCase('tr');
            let at = lower.indexOf(needle);
            if (at < 0) continue;
            const fragment = document.createDocumentFragment();
            let last = 0;
            while (at >= 0) {
              fragment.appendChild(document.createTextNode(text.slice(last, at)));
              const mark = document.createElement('mark');
              mark.className = 'find';
              mark.textContent = text.slice(at, at + needle.length);
              fragment.appendChild(mark);
              last = at + needle.length;
              at = lower.indexOf(needle, last);
            }
            fragment.appendChild(document.createTextNode(text.slice(last)));
            node.parentNode.replaceChild(fragment, node);
          }
          return log.querySelectorAll('mark.find').length;
        }
        function showCurrent() {
          const marks = log.querySelectorAll('mark.find');
          marks.forEach(m => m.classList.remove('current'));
          if (!marks.length) return { count: 0, index: 0 };
          findIndex = (findIndex + marks.length) % marks.length;
          const mark = marks[findIndex];
          mark.classList.add('current');
          for (let d = mark.closest('details'); d; d = d.parentElement.closest('details')) d.open = true;
          const prompt = mark.closest('.prompt-text.clamped');
          if (prompt) prompt.classList.remove('clamped');
          mark.scrollIntoView({ block: 'center', behavior: 'smooth' });
          stick = false;
          return { count: marks.length, index: findIndex + 1 };
        }
        function find(query) {
          if (query !== findQuery) findIndex = 0;
          findQuery = query;
          highlight(query);
          return showCurrent();
        }
        function findStep(delta) {
          findIndex += delta;
          return showCurrent();
        }
        function endFind() {
          findQuery = '';
          clearMarks();
        }

        function elapsed(since) {
          const s = Math.max(0, Math.round((Date.now() - since) / 1000));
          return s < 60 ? s + ' sn' : Math.floor(s / 60) + ' dk ' + (s % 60) + ' sn';
        }

        function setStatus(st) {
          clearInterval(statusTimer);
          statusEl.className = st.mode;
          statusEl.dataset.busy = (st.mode === 'working' || st.mode === 'waiting') ? '1' : '';
          const esc = t => t.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
          if (st.mode === 'working') {
            statusEl.innerHTML = '<span class="spark">\#(Icon.sparkle)</span><span class="shimmer">Çalışıyor</span>' +
              (st.text ? '<span class="step">' + esc(st.text) + '</span>' : '') +
              (st.since ? '<span class="elapsed"></span>' : '');
          } else if (st.mode === 'waiting') {
            statusEl.innerHTML = '<span class="spinner"></span><span class="label">Onayını bekliyor</span>' +
              (st.text ? '<span class="step">' + esc(st.text) + '</span>' : '');
          } else if (st.mode === 'starting') {
            statusEl.innerHTML = '<span class="spinner"></span><span>' + agentName + ' başlatılıyor…</span>';
          } else {
            statusEl.innerHTML = '';
          }
          const el = statusEl.querySelector('.elapsed');
          if (el && st.since) {
            const tick = () => { el.textContent = elapsed(st.since); };
            tick();
            statusTimer = setInterval(tick, 1000);
          }
          if (statusEl.dataset.busy) document.body.classList.remove('empty');
          else document.body.classList.toggle('empty', log.children.length === 0);
          if (stick) toBottom(true);
        }

        document.addEventListener('click', e => {
          const summary = e.target.closest('summary');
          if (summary && !e.target.closest('a[href]')) {
            const d = summary.parentElement;
            setTimeout(() => { if (d.dataset.key) userOpen.set(d.dataset.key, d.open); }, 0);
          }
          // Links go to the app, also inside a row's summary, where they must not fold the row.
          const link = e.target.closest('a[href]');
          if (link) {
            e.preventDefault();
            webkit.messageHandlers.tezgah.postMessage({ open: link.getAttribute('href') });
            return;
          }
          const entryButton = e.target.closest('button[data-entry-action]');
          if (entryButton) {
            webkit.messageHandlers.tezgah.postMessage({ entry: entryButton.dataset.entry, action: entryButton.dataset.entryAction });
            if (entryButton.dataset.entryAction === 'copy') {
              entryButton.classList.add('done');
              setTimeout(() => entryButton.classList.remove('done'), 1200);
            }
            return;
          }
          const button = e.target.closest('button[data-action]');
          if (!button) return;
          if (button.dataset.action === 'copy') {
            const code = button.closest('.codeblock').querySelector('pre').innerText;
            webkit.messageHandlers.tezgah.postMessage({ copy: code });
            button.textContent = 'Kopyalandı';
            setTimeout(() => { button.textContent = 'Kopyala'; }, 1400);
          } else if (button.dataset.action === 'run') {
            const code = button.closest('.codeblock').querySelector('pre').innerText;
            webkit.messageHandlers.tezgah.postMessage({ run: code });
          } else if (button.dataset.action === 'expand') {
            button.previousElementSibling.classList.remove('clamped');
            button.remove();
          }
        });

        // Typing while the conversation has focus goes to the composer.
        document.addEventListener('keydown', e => {
          if (e.metaKey || e.ctrlKey || e.altKey) return;
          if (e.key.length === 1 || e.key === 'Enter') {
            e.preventDefault();
            webkit.messageHandlers.tezgah.postMessage({ type: e.key === 'Enter' ? '' : e.key });
          }
        });
        """#
    }
}

/// Doesn't keep the coordinator alive through WebKit's strong reference to message handlers.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension ClaudeConversationView.Status {
    /// The line under the conversation for an agent's state.
    @MainActor init(_ activity: AgentActivity) {
        switch activity.state {
        case .starting: self.init(mode: .starting)
        case .idle: self.init(mode: .idle)
        case .working: self.init(mode: .working, text: activity.currentStep, since: activity.turnStartedAt)
        case .needsPermission: self.init(mode: .waiting, text: activity.message)
        case .finished: self.init(mode: .finished)
        case .ended: self.init(mode: .ended)
        }
    }
}
