import Foundation

/// A shell command the user runs often in a project, such as `make run` or `npm run dev`.
struct ProjectCommand: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var command: String
    /// Where it was found ("Makefile", "package.json"…), nil for commands the user added.
    var source: String?
    /// What it does, from the build file's comments (`build: ## Compiles` or a `#` line above).
    var detail: String?

    var id: String { command }
    var isCustom: Bool { source == nil }
}

/// Finds the commands a project's build files define.
enum ProjectCommandDetector {
    static func detect(in folder: URL) -> [ProjectCommand] {
        var commands: [ProjectCommand] = []
        func file(_ name: String) -> String? {
            try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }

        if let (name, text) = ["Makefile", "makefile", "GNUmakefile"].lazy.compactMap({ name in file(name).map { (name, $0) } }).first {
            let details = makeTargetDetails(in: text)
            commands += makeTargets(in: text).map {
                ProjectCommand(name: "make \($0)", command: "make \($0)", source: name, detail: details[$0])
            }
        }
        if let text = file("package.json") {
            let runner = packageRunner(lockFiles: Set(["bun.lockb", "bun.lock", "pnpm-lock.yaml", "yarn.lock"].filter(exists)))
            commands += packageScripts(in: text).map {
                ProjectCommand(name: "\(runner) \($0)", command: "\(runner) \($0)", source: "package.json")
            }
        }
        if exists("Package.swift") {
            commands += ["swift build", "swift test", "swift run"].map { ProjectCommand(name: $0, command: $0, source: "Package.swift") }
        }
        if exists("Cargo.toml") {
            commands += ["cargo build", "cargo test", "cargo run"].map { ProjectCommand(name: $0, command: $0, source: "Cargo.toml") }
        }
        if exists("go.mod") {
            commands += ["go build ./...", "go test ./...", "go run ."].map { ProjectCommand(name: $0, command: $0, source: "go.mod") }
        }
        if let text = file("pubspec.yaml") {
            let tool = text.contains("sdk: flutter") ? "flutter" : "dart"
            commands += ["\(tool) run", "\(tool) test", "\(tool) pub get"].map { ProjectCommand(name: $0, command: $0, source: "pubspec.yaml") }
        }
        if let (name, text) = ["justfile", "Justfile", ".justfile"].lazy.compactMap({ name in file(name).map { (name, $0) } }).first {
            commands += justRecipes(in: text).map { ProjectCommand(name: "just \($0)", command: "just \($0)", source: name) }
        }
        return commands
    }

    /// Targets a person would type: no special (.PHONY), pattern (%.o) or variable-assignment lines.
    static func makeTargets(in text: String) -> [String] {
        var targets: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, first.isLetter || first.isNumber,
                  let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") { continue } // NAME := value
            let head = line[..<colon]
            // Variable assignments, pattern rules and files (build/app.o) are not commands.
            if head.contains("=") || head.contains("%") || head.contains("$") || head.contains("/") { continue }
            for name in head.split(separator: " ").map(String.init) where !targets.contains(name) {
                targets.append(name)
            }
        }
        return targets
    }

    /// Descriptions for targets: `target: deps ## text` (the self-documenting Makefile style),
    /// or the comment lines right above the target.
    static func makeTargetDetails(in text: String) -> [String: String] {
        var details: [String: String] = [:]
        var comment: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") {
                comment.append(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                continue
            }
            defer { if !line.hasPrefix("\t") { comment = [] } }
            guard let first = line.first, first.isLetter || first.isNumber,
                  let colon = line.firstIndex(of: ":"), !line[line.index(after: colon)...].hasPrefix("=") else { continue }
            let head = line[..<colon]
            guard !head.contains("=") else { continue }
            var detail: String?
            if let marker = line.range(of: "##") {
                detail = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            } else if !comment.isEmpty {
                detail = comment.joined(separator: " ")
            }
            guard let detail, !detail.isEmpty else { continue }
            for name in head.split(separator: " ") where details[String(name)] == nil {
                details[String(name)] = detail
            }
        }
        return details
    }

    static func packageScripts(in json: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        // JSON objects have no order once parsed; take it from the text so the list matches the file.
        return scripts.keys.sorted { lhs, rhs in
            let left = json.range(of: "\"\(lhs)\"")?.lowerBound ?? json.endIndex
            let right = json.range(of: "\"\(rhs)\"")?.lowerBound ?? json.endIndex
            return left < right
        }
    }

    static func packageRunner(lockFiles: Set<String>) -> String {
        if lockFiles.contains("bun.lockb") || lockFiles.contains("bun.lock") { return "bun run" }
        if lockFiles.contains("pnpm-lock.yaml") { return "pnpm" }
        if lockFiles.contains("yarn.lock") { return "yarn" }
        return "npm run"
    }

    static func justRecipes(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let first = line.first, first.isLetter || first == "_",
                  let colon = line.firstIndex(of: ":"), !line[colon...].hasPrefix(":=") else { return nil }
            let name = line[..<colon].split(separator: " ").first.map(String.init)
            return name.flatMap { $0.hasPrefix("_") ? nil : $0 }
        }
    }
}
