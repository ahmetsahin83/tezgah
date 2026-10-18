import Foundation

/// Remote Control, driven the way the user would at the keyboard: /remote-control asks to enable it
/// in a session that does not have it, and offers "Disconnect this session" in one that does. The
/// status line shows "/rc connecting…" then "/rc active", and the session's claude.ai link is printed.
///
/// Measured against Claude Code 2.1.296.
extension TerminalSession {
    /// What the screen last said about Remote Control; nil when it says nothing. The messages are
    /// printed once rather than kept at the bottom, so the most recent one wins.
    static func remoteControlState(in lines: [String]) -> ClaudeActivity.RemoteControl? {
        let recent = lines.suffix(120)
        let link = recent.reversed().lazy.compactMap { line -> URL? in
            guard let match = line.firstMatch(of: #/https://claude\.ai/code/session_[A-Za-z0-9]+/#) else { return nil }
            return URL(string: String(match.0))
        }.first
        for line in recent.reversed() {
            if line.contains("Remote Control disconnected") { return .off }
            if line.contains("/rc active") || line.contains("remote-control is active") { return .active(link) }
            if line.contains("/rc connecting") { return .connecting }
        }
        return nil
    }

    /// Turns Remote Control on in a running session. Returns an error message on failure.
    func enableRemoteControl() async -> String? {
        guard let claude, claude.state != .ended else { return "Claude oturumu çalışmıyor." }
        if claude.remoteControl.isOn { return nil }
        let opened = await openMenu("/remote-control") { lines in
            lines.contains { $0.contains("Enable Remote Control") } || Self.remoteControlState(in: lines)?.isOn == true
        }
        guard opened else { return "Remote Control penceresi açılmadı." }
        if view.bufferLines().suffix(30).contains(where: { $0.contains("Enable Remote Control") }) {
            view.send(txt: "1")
        }
        claude.remoteControl = .connecting
        watchRemoteControl()
        return nil
    }

    /// Disconnects Remote Control; the session keeps running here.
    func disableRemoteControl() async -> String? {
        guard let claude, claude.remoteControl.isOn else { return nil }
        guard await openMenu("/remote-control", until: { $0.contains { $0.contains("Disconnect this session") } }) else {
            return "Remote Control menüsü açılmadı."
        }
        // ❯ marks the highlighted option; Disconnect is the first one.
        for _ in 0..<4 {
            let highlighted = view.bufferLines().suffix(20).last { $0.contains("❯") } ?? ""
            if highlighted.contains("Disconnect") { break }
            view.send(txt: "\u{1B}[A")
            try? await Task.sleep(for: .milliseconds(120))
        }
        view.send(txt: "\r")
        let gone = await waitForScreen { Self.remoteControlState(in: $0) == .off }
        if gone { claude.remoteControl = .off }
        return gone ? nil : "Remote Control kapanmadı."
    }

    /// Follows the screen after Remote Control was turned on until it is connected and its link is known.
    /// Claude Code prints both once, so there is nothing to follow after that.
    func watchRemoteControl() {
        guard remoteControlWatch == nil else { return }
        remoteControlWatch = Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let claude = self.claude,
                      claude.remoteControl.isOn, claude.state != .ended else { break }
                if case .active(let link)? = Self.remoteControlState(in: self.view.bufferLines()) {
                    claude.remoteControl = .active(link)
                    if link != nil { break }
                }
            }
            self?.remoteControlWatch = nil
        }
    }
}
