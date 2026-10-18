import AppKit
import SwiftUI

extension NSTextView {
    /// Turns off the prose helpers that mangle code and commit messages.
    func disableSmartSubstitutions() {
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
    }
}

/// A plain multi-line text field. Unlike SwiftUI's TextEditor it never turns quotes into “smart quotes”.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 12)
    /// ⌘↩ while typing here, e.g. to commit.
    var onCommandReturn: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.disableSmartSubstitutions()
        textView.font = font
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommandReturn = onCommandReturn
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCommandReturn: (() -> Void)?

        init(text: Binding<String>) {
            self.text = text
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let onCommandReturn, selector == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            onCommandReturn()
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
