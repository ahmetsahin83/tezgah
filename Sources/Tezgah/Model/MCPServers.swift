import Foundation

/// MCP servers configured in Claude Code itself (`claude mcp …`), which every Claude session in
/// Tezgah also gets. Tezgah's own tools are separate and always on unless turned off.
enum MCPServers {
    struct Server: Identifiable, Equatable {
        let name: String
        let target: String
        let status: String
        var id: String { name }
        /// Connectors from the claude.ai account; managed there, not here.
        var isAccountConnector: Bool { name.hasPrefix("claude.ai ") }
        var isConnected: Bool { status.contains("✔") || status.lowercased().contains("connected") }
        var needsAuth: Bool { status.lowercased().contains("auth") }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case user, local, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .user: "Tüm projeler"
            case .local: "Bu proje (yalnız ben)"
            case .project: "Bu proje (.mcp.json, ekiple paylaşılır)"
            }
        }
    }

    struct Preset: Identifiable {
        let name: String
        let detail: String
        let isHTTP: Bool
        let target: String
        var id: String { name }
    }

    /// Starting points; the form shows exactly what will be added before anything runs.
    static let presets: [Preset] = [
        Preset(name: "sentry", detail: "Üretim hataları", isHTTP: true, target: "https://mcp.sentry.dev/mcp"),
        Preset(name: "linear", detail: "Linear işleri", isHTTP: true, target: "https://mcp.linear.app/mcp"),
        Preset(name: "context7", detail: "Kütüphanelerin güncel dokümanları", isHTTP: false, target: "npx -y @upstash/context7-mcp"),
        Preset(name: "github", detail: "Issue, PR, CI (token gerekir)", isHTTP: true, target: "https://api.githubcopilot.com/mcp/"),
    ]

    static func list(in folder: URL) async throws -> [Server] {
        let output = try await claude(["mcp", "list"], in: folder)
        return output.split(separator: "\n").compactMap { line in
            guard let match = String(line).firstMatch(of: #/^(.+?): (.+) - (.+)$/#) else { return nil }
            return Server(name: String(match.1), target: String(match.2), status: String(match.3).trimmingCharacters(in: .whitespaces))
        }
    }

    static func add(name: String, target: String, isHTTP: Bool, scope: Scope, headers: [String], environment: [String], in folder: URL) async throws {
        var args = ["mcp", "add", "--scope", scope.rawValue]
        if isHTTP {
            args += ["--transport", "http"]
            for header in headers where !header.isEmpty { args += ["--header", header] }
            args += [name, target]
        } else {
            for variable in environment where !variable.isEmpty { args += ["-e", variable] }
            args += [name, "--"] + target.split(separator: " ").map(String.init)
        }
        _ = try await claude(args, in: folder)
    }

    static func remove(_ name: String, in folder: URL) async throws {
        _ = try await claude(["mcp", "remove", name], in: folder)
    }

    private static func claude(_ args: [String], in folder: URL) async throws -> String {
        guard let path = await WorkspaceStore.findClaude() else { throw MCPError("Claude Code bulunamadı.") }
        let environment = await ShellEnvironment.shared.environment()
            .filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                process.currentDirectoryURL = folder
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errorData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    let message = String(decoding: errorData.isEmpty ? data : errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: MCPError(message.isEmpty ? "claude \(args.joined(separator: " ")) başarısız" : message))
                }
            }
        }
    }

    struct MCPError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
