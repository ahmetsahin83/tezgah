import Observation
import WebKit

/// Lets SwiftUI controls (the find bar) talk to the conversation page.
@MainActor
@Observable
final class ClaudeConversationController {
    @ObservationIgnored weak var webView: WKWebView?

    var isFinding = false
    /// Bumped to put the cursor in the find field (⌘F again while it is open).
    var focusRequest = 0
    var query = ""
    /// Matches of `query`, and which one is shown (1-based, 0 when none).
    private(set) var matchCount = 0
    private(set) var matchIndex = 0

    func find() {
        evaluate("find(\(Self.json(query)))")
    }

    func step(_ delta: Int) {
        guard !query.isEmpty else { return }
        evaluate("findStep(\(delta))")
    }

    func endFind() {
        isFinding = false
        query = ""
        matchCount = 0
        matchIndex = 0
        webView?.evaluateJavaScript("endFind()", completionHandler: nil)
    }

    private func evaluate(_ script: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let values = result as? [String: Any]
                self?.matchCount = (values?["count"] as? NSNumber)?.intValue ?? 0
                self?.matchIndex = (values?["index"] as? NSNumber)?.intValue ?? 0
            }
        }
    }

    private static func json(_ text: String) -> String {
        (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
    }
}
