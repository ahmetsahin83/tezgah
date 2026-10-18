import AppKit
import CodeEditSourceEditor

/// Which lines of a file differ from the version in git's index, VS Code style:
/// added lines, modified lines and spots where lines were deleted.
struct LineChanges: Equatable, Sendable {
    /// 0-based line numbers in the current text.
    var added = IndexSet()
    var modified = IndexSet()
    /// Lines were deleted just above this line (== line count: at the end of the file).
    var deletedAbove = IndexSet()

    var isEmpty: Bool { added.isEmpty && modified.isEmpty && deletedAbove.isEmpty }

    /// Files longer than this are not compared, to keep typing smooth.
    static let maxLines = 20_000

    static func compute(base: String, current: String) -> LineChanges {
        let old = base.split(separator: "\n", omittingEmptySubsequences: false)
        let new = current.split(separator: "\n", omittingEmptySubsequences: false)
        guard old.count <= maxLines, new.count <= maxLines else { return LineChanges() }

        var removed = IndexSet()
        var inserted = IndexSet()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk both files in step: unchanged lines pair up one to one, so each run of removed and
        // inserted lines between them is one hunk. Lines replaced in place count as modified.
        var changes = LineChanges()
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            var removedRun = 0
            while removed.contains(oldIndex + removedRun) { removedRun += 1 }
            var insertedRun = 0
            while inserted.contains(newIndex + insertedRun) { insertedRun += 1 }

            if removedRun == 0 && insertedRun == 0 {
                oldIndex += 1
                newIndex += 1
                continue
            }
            let replaced = min(removedRun, insertedRun)
            changes.modified.insert(integersIn: newIndex..<newIndex + replaced)
            if insertedRun > removedRun {
                changes.added.insert(integersIn: newIndex + replaced..<newIndex + insertedRun)
            } else if removedRun > insertedRun {
                changes.deletedAbove.insert(newIndex + insertedRun)
            }
            oldIndex += removedRun
            newIndex += insertedRun
        }
        return changes
    }
}

/// Draws change bars in the free strip at the left edge of the editor's line numbers.
final class GutterMarksView: NSView {
    weak var controller: TextViewController?
    var changes = LineChanges() {
        didSet { if changes != oldValue { needsDisplay = true } }
    }

    static let width: CGFloat = 6

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let layoutManager = controller?.textView.layoutManager, !changes.isEmpty else { return }
        let lineCount = layoutManager.lineCount
        for line in layoutManager.linesStartingAt(dirtyRect.minY, until: dirtyRect.maxY) {
            let bar = NSRect(x: 2, y: line.yPos, width: 3, height: line.height)
            if changes.added.contains(line.index) {
                NSColor.systemGreen.setFill()
                bar.fill()
            } else if changes.modified.contains(line.index) {
                NSColor.systemBlue.setFill()
                bar.fill()
            }
            if changes.deletedAbove.contains(line.index) {
                drawDeletion(at: line.yPos)
            }
            if line.index == lineCount - 1, changes.deletedAbove.contains(lineCount) {
                drawDeletion(at: line.yPos + line.height)
            }
        }
    }

    /// A small red wedge pointing at the gap where lines were removed.
    private func drawDeletion(at y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y - 4))
        path.line(to: NSPoint(x: Self.width, y: y))
        path.line(to: NSPoint(x: 0, y: y + 4))
        path.close()
        NSColor.systemRed.setFill()
        path.fill()
    }
}

/// Installs the marks view into the editor's gutter once it is on screen.
final class GutterMarksCoordinator: TextViewCoordinator {
    let marksView = GutterMarksView()
    var onTextChange: (() -> Void)?
    var onAppear: (() -> Void)?

    func prepareCoordinator(controller: TextViewController) {}

    func controllerDidAppear(controller: TextViewController) {
        if marksView.superview == nil, let gutter = Self.findGutter(in: controller.view) {
            marksView.controller = controller
            marksView.frame = NSRect(x: 0, y: 0, width: GutterMarksView.width, height: gutter.bounds.height)
            marksView.autoresizingMask = [.height]
            gutter.addSubview(marksView)
        }
        onAppear?()
    }

    func textViewDidChangeText(controller: TextViewController) {
        onTextChange?()
    }

    private static func findGutter(in view: NSView) -> GutterView? {
        if let gutter = view as? GutterView { return gutter }
        for subview in view.subviews {
            if let gutter = findGutter(in: subview) { return gutter }
        }
        return nil
    }
}
