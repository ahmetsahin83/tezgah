import Foundation

struct GitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct GitOutput {
    let stdout: Data
    let stderr: String
    let exitCode: Int32

    var text: String { String(decoding: stdout, as: UTF8.self) }
    var lines: [String] { text.split(separator: "\n").map(String.init) }
}

enum Git {
    private static let baseArguments = ["-c", "core.quotepath=false", "-c", "color.ui=false"]

    /// Runs `git args` in `directory` off the main thread.
    /// Throws with git's stderr when the exit code is not in `allowedExitCodes`.
    static func run(
        _ args: [String],
        in directory: URL,
        input: String? = nil,
        allowedExitCodes: Set<Int32> = [0],
        environment extraEnvironment: [String: String] = [:]
    ) async throws -> GitOutput {
        var environment = await ShellEnvironment.shared.environment().merging(extraEnvironment) { $1 }
        environment["GIT_TERMINAL_PROMPT"] = "0" // fail instead of waiting for a password prompt nobody sees
        environment["GIT_OPTIONAL_LOCKS"] = "0" // polling `git status` must not fight the user's own git commands

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["git"] + baseArguments + args
                process.currentDirectoryURL = directory
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                let stdin = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let input {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }

                // Drain both pipes concurrently so a large stderr cannot block stdout.
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                let output = GitOutput(
                    stdout: outputData,
                    stderr: String(decoding: errorData, as: UTF8.self),
                    exitCode: process.terminationStatus
                )
                if allowedExitCodes.contains(output.exitCode) {
                    continuation.resume(returning: output)
                } else {
                    let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: GitError(
                        message: message.isEmpty ? "git \(args.first ?? "") başarısız oldu (çıkış kodu \(output.exitCode))" : message
                    ))
                }
            }
        }
    }
}

/// The user's login-shell environment. Apps started from Finder get launchd's minimal PATH,
/// so without this, git hooks (husky, lint-staged…) would not find node, brew tools and so on.
actor ShellEnvironment {
    static let shared = ShellEnvironment()

    private var resolving: Task<[String: String], Never>?

    func environment() async -> [String: String] {
        if let resolving { return await resolving.value }
        let task = Task.detached(priority: .userInitiated) { Self.resolve() }
        resolving = task
        return await task.value
    }

    private static func resolve() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let marker = "__TEZGAH_ENV__"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        // Collect output until both markers arrive. Reading to EOF could hang forever if the
        // shell config starts a background process that inherits stdout.
        let buffer = LockedBuffer()
        let done = DispatchSemaphore(value: 0)
        let markerData = Data(marker.utf8)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            let received = buffer.append(chunk)
            if chunk.isEmpty || received.ranges(of: markerData).count >= 2 {
                handle.readabilityHandler = nil
                done.signal()
            }
        }

        do {
            try process.run()
        } catch {
            return environment
        }
        _ = done.wait(timeout: .now() + 5)
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }

        let text = String(decoding: buffer.data, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return environment }

        for entry in parts[1].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data { lock.withLock { storage } }

    /// Appends and returns everything received so far.
    func append(_ chunk: Data) -> Data {
        lock.withLock {
            storage.append(chunk)
            return storage
        }
    }
}

extension Git {
    /// Pushes the checked-out branch: to its upstream, or to origin (the first remote) with one set
    /// up. Never forces; throws git's reason when the remote won't take it.
    static func push(in root: URL) async throws {
        if (try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: root)) != nil {
            _ = try await run(["push"], in: root)
            return
        }
        let remotes = try await run(["remote"], in: root).lines
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            throw GitError(message: "Bu depoda uzak depo (remote) tanımlı değil.")
        }
        _ = try await run(["push", "-u", remote, "HEAD"], in: root)
    }
}
