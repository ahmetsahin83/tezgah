import Foundation

/// Searching file contents across a project with ripgrep, git grep or grep, whichever is available.
enum TextSearch {
    struct Options: Equatable, Sendable {
        var query = ""
        var isCaseSensitive = false
        var isRegex = false
        var isWholeWord = false
        /// Comma-separated globs; a leading "!" excludes ("*.swift, !Tests/**").
        var include = ""

        var globs: [String] {
            include.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    struct Match: Identifiable, Sendable, Equatable {
        let id: Int
        /// 1-based.
        let line: Int
        let text: String
        /// UTF-16 ranges of the hits in `text`.
        let ranges: [NSRange]
    }

    struct FileResult: Identifiable, Sendable, Equatable {
        /// Relative to the searched folder.
        let path: String
        var matches: [Match]

        var id: String { path }
    }

    struct Output: Sendable, Equatable {
        var files: [FileResult] = []
        var matchCount = 0
        /// Stopped early at `maxMatches`.
        var isTruncated = false
    }

    enum Tool: Equatable, Sendable {
        case ripgrep(String)
        case gitGrep
        case grep
    }

    static let maxMatches = 5000
    /// Longer lines are cut around the first hit; minified files would otherwise flood the list.
    static let maxLineLength = 400

    static func tool(for folder: URL) async -> Tool {
        let environment = await ShellEnvironment.shared.environment()
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        if let rg = folders.map({ ($0 as NSString).appendingPathComponent("rg") }).first(where: FileManager.default.isExecutableFile) {
            return .ripgrep(rg)
        }
        if (try? await Git.run(["rev-parse", "--is-inside-work-tree"], in: folder)) != nil {
            return .gitGrep
        }
        return .grep
    }

    /// The command line for a search. Every tool prints "path NUL line:text" or "path NUL line NUL text".
    static func arguments(for options: Options, tool: Tool) -> (executable: String, arguments: [String]) {
        var flags: [String] = []
        if !options.isCaseSensitive { flags.append("-i") }
        if !options.isRegex { flags.append("-F") }
        if options.isWholeWord { flags.append("-w") }
        let globs = options.globs

        switch tool {
        case .ripgrep(let path):
            var args = ["--no-heading", "--with-filename", "--line-number", "--color", "never", "--null", "--no-messages"]
            args += flags
            for glob in globs { args += ["-g", glob] }
            return (path, args + ["-e", options.query, "--", "."])
        case .gitGrep:
            var args = ["git", "-c", "core.quotepath=false", "grep", "-n", "-z", "-I", "--untracked", "--exclude-standard", "--no-color"]
            args += flags
            if options.isRegex { args.append("-E") }
            args += ["-e", options.query, "--"]
            args += globs.isEmpty ? ["."] : globs.map { $0.hasPrefix("!") ? ":(exclude,glob)**/\($0.dropFirst())" : ":(glob)**/\($0)" }
            return ("/usr/bin/env", args)
        case .grep:
            var args = ["grep", "-r", "-n", "-I", "--null"]
            args += flags
            if options.isRegex { args.append("-E") }
            for folder in FileIndex.skippedFolders { args.append("--exclude-dir=\(folder)") }
            for glob in globs {
                args.append(glob.hasPrefix("!") ? "--exclude=\(glob.dropFirst())" : "--include=\(glob)")
            }
            return ("/usr/bin/env", args + ["-e", options.query, "."])
        }
    }

    static func run(_ options: Options, in folder: URL) async throws -> Output {
        let tool = await tool(for: folder)
        let (executable, arguments) = arguments(for: options, tool: tool)
        let environment = await ShellEnvironment.shared.environment()
        let highlighter = Highlighter(options)
        let running = RunningProcess()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.currentDirectoryURL = folder
                    process.environment = environment
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    process.standardInput = FileHandle.nullDevice
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    running.set(process)

                    var parser = OutputParser(highlighter: highlighter)
                    let reader = stdout.fileHandleForReading
                    while true {
                        let chunk = reader.availableData
                        if chunk.isEmpty { break }
                        parser.consume(chunk)
                        if parser.output.isTruncated {
                            process.terminate()
                            break
                        }
                    }
                    parser.finish()
                    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    running.set(nil)

                    // grep tools exit with 1 for "nothing found"; 2 and up are real errors (bad regex…).
                    if process.terminationReason == .exit, process.terminationStatus > 1, parser.output.matchCount == 0 {
                        let message = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: GitError(message: message.isEmpty ? "Arama başarısız oldu." : message))
                    } else {
                        continuation.resume(returning: parser.output)
                    }
                }
            }
        } onCancel: {
            running.terminate()
        }
    }

    /// Finds the hits within a line, for bold highlighting; the tools only report the line.
    struct Highlighter: Sendable {
        private let expression: NSRegularExpression?

        init(_ options: Options) {
            var pattern = options.isRegex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
            if options.isWholeWord { pattern = "\\b(?:\(pattern))\\b" }
            expression = try? NSRegularExpression(pattern: pattern, options: options.isCaseSensitive ? [] : [.caseInsensitive])
        }

        func ranges(in text: String) -> [NSRange] {
            guard let expression else { return [] }
            return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .map(\.range)
                .filter { $0.length > 0 }
        }
    }

    /// Splits tool output into files and lines as it streams in.
    struct OutputParser {
        let highlighter: Highlighter
        private(set) var output = Output()
        private var buffer = Data()
        private var indexByPath: [String: Int] = [:]

        init(highlighter: Highlighter) {
            self.highlighter = highlighter
        }

        mutating func consume(_ data: Data) {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                parse(line)
                if output.isTruncated { return }
            }
        }

        mutating func finish() {
            if !buffer.isEmpty, !output.isTruncated { parse(buffer) }
            buffer = Data()
        }

        private mutating func parse(_ line: Data) {
            // "path\0" then "12:text" (rg, grep) or "12\0text" (git grep).
            guard let nul = line.firstIndex(of: 0) else { return }
            var path = String(decoding: line[line.startIndex..<nul], as: UTF8.self)
            if path.hasPrefix("./") { path.removeFirst(2) }
            let rest = line[line.index(after: nul)...]
            guard let separator = rest.firstIndex(where: { $0 == 0 || $0 == 0x3A /* : */ }),
                  let number = Int(String(decoding: rest[rest.startIndex..<separator], as: UTF8.self)) else { return }
            var text = String(decoding: rest[rest.index(after: separator)...], as: UTF8.self)
            if text.hasSuffix("\r") { text.removeLast() }
            text = text.replacingOccurrences(of: "\t", with: "    ")

            var ranges = highlighter.ranges(in: text)
            let length = (text as NSString).length
            if length > TextSearch.maxLineLength {
                // Keep a window around the first hit.
                let start = max(0, (ranges.first?.location ?? 0) - 60)
                let window = NSRange(location: start, length: min(TextSearch.maxLineLength, length - start))
                text = (start > 0 ? "…" : "") + (text as NSString).substring(with: window) + "…"
                let shift = start > 0 ? 1 - start : 0
                ranges = ranges.compactMap { range in
                    guard NSIntersectionRange(range, window).length > 0 else { return nil }
                    let clipped = NSIntersectionRange(range, window)
                    return NSRange(location: clipped.location + shift, length: clipped.length)
                }
            }

            let match = Match(id: output.matchCount, line: number, text: text, ranges: ranges)
            if let index = indexByPath[path] {
                output.files[index].matches.append(match)
            } else {
                indexByPath[path] = output.files.count
                output.files.append(FileResult(path: path, matches: [match]))
            }
            output.matchCount += 1
            if output.matchCount >= TextSearch.maxMatches { output.isTruncated = true }
        }
    }
}

/// A search's process, so cancelling the task stops it.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process?) {
        lock.withLock { self.process = process }
    }

    func terminate() {
        lock.withLock {
            if process?.isRunning == true { process?.terminate() }
        }
    }
}
