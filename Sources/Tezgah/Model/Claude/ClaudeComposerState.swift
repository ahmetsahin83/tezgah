import AppKit
import Foundation
import Observation

/// The draft in a Claude tab's composer. Lives with the session, so it survives tab switches.
@MainActor
@Observable
final class ClaudeComposerState {
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// Pasted screenshots are saved to a temporary file Tezgah owns.
        let isTemporary: Bool

        var isImage: Bool {
            ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(url.pathExtension.lowercased())
        }
    }

    var text = ""
    var attachments: [Attachment] = []
    /// Bumped to ask the text view to take focus.
    private(set) var focusRequest = 0
    /// Text to insert at the cursor (type-ahead from the conversation view).
    var pendingInsertion: String?
    /// Where to put the cursor after the text was changed from outside the text view.
    var pendingCursor: Int?
    /// Sent while the agent was still starting: goes out as soon as it is ready.
    var isWaitingForAgent = false

    /// Earlier prompts, newest last, for ↑ / ↓.
    @ObservationIgnored private(set) var history: [String] = []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var draftBeforeHistory = ""

    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    func focus() {
        focusRequest += 1
    }

    func typeAhead(_ characters: String) {
        pendingInsertion = (pendingInsertion ?? "") + characters
        focus()
    }

    func addAttachment(_ url: URL, isTemporary: Bool = false) {
        guard !attachments.contains(where: { $0.url == url }) else { return }
        attachments.append(Attachment(url: url, isTemporary: isTemporary))
    }

    /// Saves pasted image data (a screenshot, an image copied from a browser) as a PNG to attach.
    func attachImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tezgah-Claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Görsel \(formatter.string(from: .now))-\(attachments.count + 1).png")
        guard (try? png.write(to: url)) != nil else { return }
        addAttachment(url, isTemporary: true)
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Takes the draft for sending and clears the composer.
    func takeDraft() -> (text: String, attachments: [URL]) {
        let draft = (text, attachments.map(\.url))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, history.last != trimmed { history.append(trimmed) }
        text = ""
        attachments = []
        historyIndex = nil
        return draft
    }

    /// Fills the history from the conversation, e.g. after resuming a session.
    func seedHistory(_ prompts: [String]) {
        guard history.isEmpty else { return }
        history = prompts
    }

    /// ↑: an older prompt. Returns false when there is nothing older.
    func previousFromHistory() -> Bool {
        guard !history.isEmpty else { return false }
        let index: Int
        if let current = historyIndex {
            guard current > 0 else { return false }
            index = current - 1
        } else {
            draftBeforeHistory = text
            index = history.count - 1
        }
        historyIndex = index
        text = history[index]
        return true
    }

    /// ↓: a newer prompt, then back to the draft.
    func nextFromHistory() -> Bool {
        guard let current = historyIndex else { return false }
        if current + 1 < history.count {
            historyIndex = current + 1
            text = history[current + 1]
        } else {
            historyIndex = nil
            text = draftBeforeHistory
        }
        return true
    }

    var isBrowsingHistory: Bool { historyIndex != nil }
}

/// Slash commands offered in the composer: Claude Code's own, plus the user's and the project's.
struct ClaudeSlashCommand: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    /// Opens a menu or dialog in Claude Code's terminal UI, so the tab switches to the terminal.
    let isInteractive: Bool

    var id: String { name }

    static let builtIn: [ClaudeSlashCommand] = [
        .init(name: "clear", summary: "Konuşmayı temizle, yeni oturum başlat", isInteractive: false),
        .init(name: "compact", summary: "Konuşmayı özetleyip bağlamı boşalt", isInteractive: false),
        .init(name: "context", summary: "Bağlam penceresinin kullanımını göster", isInteractive: false),
        .init(name: "init", summary: "Proje için CLAUDE.md oluştur", isInteractive: false),
        .init(name: "review", summary: "Değişiklikleri incele", isInteractive: false),
        .init(name: "cost", summary: "Oturumun maliyeti ve süresi", isInteractive: false),
        .init(name: "model", summary: "Modeli değiştir", isInteractive: true),
        .init(name: "resume", summary: "Önceki bir konuşmaya dön", isInteractive: true),
        .init(name: "rewind", summary: "Konuşmayı ve kodu önceki bir noktaya geri al", isInteractive: true),
        .init(name: "permissions", summary: "İzin kurallarını düzenle", isInteractive: true),
        .init(name: "memory", summary: "CLAUDE.md belleğini düzenle", isInteractive: true),
        .init(name: "agents", summary: "Alt ajanları yönet", isInteractive: true),
        .init(name: "mcp", summary: "MCP sunucularını yönet", isInteractive: true),
        .init(name: "hooks", summary: "Hook'ları yönet", isInteractive: true),
        .init(name: "config", summary: "Ayarlar", isInteractive: true),
        .init(name: "status", summary: "Sürüm, hesap ve bağlantı durumu", isInteractive: true),
        .init(name: "usage", summary: "Plan kullanım limitleri", isInteractive: true),
        .init(name: "add-dir", summary: "Çalışma klasörü ekle", isInteractive: false),
        .init(name: "export", summary: "Konuşmayı dışa aktar", isInteractive: true),
        .init(name: "help", summary: "Yardım ve kısayollar", isInteractive: true),
    ]

    /// Commands and skills from ~/.claude and the project's .claude folder.
    static func discover(projectURL: URL, configDirectory: URL) -> [ClaudeSlashCommand] {
        var found: [String: ClaudeSlashCommand] = [:]
        for base in [configDirectory, projectURL.appendingPathComponent(".claude", isDirectory: true)] {
            let commands = base.appendingPathComponent("commands", isDirectory: true)
            if let enumerator = FileManager.default.enumerator(at: commands, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator where url.pathExtension == "md" {
                    let relative = url.path.dropFirst(commands.path.count + 1).dropLast(3)
                    let name = relative.replacingOccurrences(of: "/", with: ":")
                    found[name] = .init(name: name, summary: description(of: url) ?? "Özel komut", isInteractive: false)
                }
            }
            let skills = base.appendingPathComponent("skills", isDirectory: true)
            for folder in (try? FileManager.default.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil)) ?? [] {
                let file = folder.appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let name = folder.lastPathComponent
                found[name] = .init(name: name, summary: description(of: file) ?? "Skill", isInteractive: false)
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// `description:` from the file's front matter.
    private static func description(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8), text.hasPrefix("---") else { return nil }
        try? handle.close()
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            if line.hasPrefix("description:") {
                let value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }
}
