import AppKit

/// Confirmation for actions that lose data or change it for good, as a sheet on Tezgah's window.
///
/// The confirming button needs a click or ⌘↩: Return alone does nothing, so a key pressed while
/// typing elsewhere can't confirm it. Esc cancels. A sheet also waits for an answer however the
/// app is shown, unlike an app-modal alert.
@MainActor
enum ConfirmSheet {
    /// The sheet waiting for an answer, which can also come from elsewhere (Telegram).
    private static var current: (id: UUID, alert: NSAlert, window: NSWindow)?

    static func ask(
        title: String, message: String, confirm: String, cancel: String = "Vazgeç", destructive: Bool = true, id: UUID = UUID()
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .warning
        alert.messageText = title
        alert.informativeText = message + "\n\nOnaylamak için tıkla ya da ⌘↩."
        let ok = alert.addButton(withTitle: confirm)
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = .command
        ok.hasDestructiveAction = destructive
        let no = alert.addButton(withTitle: cancel)
        no.keyEquivalent = "\u{1b}"
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil }) else {
            return false
        }
        if window.attachedSheet != nil { return false } // one question at a time
        window.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.informationalRequest)
        current = (id, alert, window)
        defer { if current?.id == id { current = nil } }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// Answers sheet `id` as its buttons would; false when it's gone.
    @discardableResult
    static func answer(_ id: UUID, confirm: Bool) -> Bool {
        guard let current, current.id == id else { return false }
        current.window.endSheet(current.alert.window, returnCode: confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        return true
    }
}
