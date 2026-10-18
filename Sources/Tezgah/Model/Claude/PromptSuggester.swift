import Foundation

/// Guesses what the user may want to ask next, after each of Claude's turns, like the Claude
/// desktop app does: a quick, tool-less call to a small model with the last exchange.
enum PromptSuggester {
    static let enabledKey = "claudePromptSuggestions"

    @MainActor static var isEnabled: Bool { AppSettings.shared.promptSuggestions }

    static let systemPrompt = """
    You suggest what the user might ask a coding assistant next, given their last message and the \
    assistant's reply. Reply with ONLY a JSON array of up to 3 short follow-up prompts, each at most 9 \
    words, written as the user would type them, in the same language as the user's message. Make them \
    concrete next steps for this work (verify, extend, fix what is left, commit), not generic questions. \
    If nothing sensible follows, reply with [].
    """

    /// Runs `claude -p` with no tools, no settings and no saved session, from a scratch folder so the
    /// project's CLAUDE.md doesn't come along.
    static func suggest(prompt: String, reply: String, claudePath: String) async -> [String] {
        let input = "User's last message:\n\(prompt.prefix(2000))\n\nAssistant's reply:\n\(reply.suffix(3000))\n"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tezgah-suggest", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let environment = await ShellEnvironment.shared.environment()
            .filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" && !$0.key.hasPrefix("TEZGAH_") }

        let output: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = [
                    "-p", "--model", "haiku", "--no-session-persistence", "--setting-sources", "",
                    "--tools", "", "--strict-mcp-config", "--system-prompt", systemPrompt,
                ]
                process.currentDirectoryURL = folder
                process.environment = environment
                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
                // Never hold on to a stuck call.
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
        return output.map(parse) ?? []
    }

    /// The JSON array in the model's answer, tolerating text or code fences around it.
    static func parse(_ text: String) -> [String] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let array = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [Any] else { return [] }
        return array.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 120 }
            .prefix(3)
            .map { $0 }
    }
}
