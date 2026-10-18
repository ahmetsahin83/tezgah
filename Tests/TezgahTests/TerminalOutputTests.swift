import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct TerminalOutputTests {
    @Test func readsWhatTheShellPrints() async throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory, title: "t", command: "printf '\\033[32mtezgah-%s\\033[0m\\n' $((40+2)); sleep 5")
        defer { session.terminate() }
        for _ in 0..<100 where !session.view.bufferLines().contains("tezgah-42") {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.view.bufferLines().contains("tezgah-42")) // colors gone, text kept
    }

    /// Closing a tab stops its program, as the warning before it promises, even though an
    /// interactive shell ignores the SIGTERM SwiftTerm sends.
    @Test func closingStopsWhatRunsInTheTab() async throws {
        // Oh My Zsh may otherwise ask about updating before the command runs.
        let quiet = ["DISABLE_AUTO_UPDATE": "true", "DISABLE_UPDATE_PROMPT": "true"]
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory, title: "t", command: "sleep 600; true", environment: quiet)
        var job: pid_t?
        for _ in 0..<200 where job == nil {
            try await Task.sleep(for: .milliseconds(50))
            if session.foregroundProcessName == "sleep", let process = session.view.process {
                job = ProcessInspector.foregroundGroup(ofTerminal: process.childfd)
            }
        }
        let sleep = try #require(job)
        session.terminate()
        for _ in 0..<100 where kill(sleep, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(sleep, 0) != 0)
    }
}
