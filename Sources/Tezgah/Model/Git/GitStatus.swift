import Foundation
import SwiftUI

struct GitChange: Identifiable, Hashable, Sendable {
    enum Area: String, Sendable { case staged, unstaged, conflicted }

    /// Path relative to the repository root.
    let path: String
    /// Source path of a rename or copy.
    let originalPath: String?
    /// Git's status letter for this area: M, A, D, R, C, T, ? (untracked) or U (conflict).
    let code: Character
    let area: Area

    var id: String { "\(area.rawValue):\(path)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var isUntracked: Bool { code == "?" }

    /// Letters as VS Code shows them.
    var letter: String { Self.letter(for: code, area: area) }
    var color: Color { Self.color(for: code, area: area) }

    static func letter(for code: Character, area: Area) -> String {
        if area == .conflicted { return "!" }
        return code == "?" ? "U" : String(code)
    }

    static func color(for code: Character, area: Area) -> Color {
        if area == .conflicted { return .red }
        switch code {
        case "?", "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }
}

struct GitStatus: Equatable, Sendable {
    var branch: String?
    var headOID: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged: [GitChange] = []
    var unstaged: [GitChange] = []
    var conflicted: [GitChange] = []

    var isClean: Bool { staged.isEmpty && unstaged.isEmpty && conflicted.isEmpty }
    var allChanges: [GitChange] { conflicted + staged + unstaged }

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parse(_ data: Data) -> GitStatus {
        var status = GitStatus()
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1

            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": status.headOID = parts[1] == "(initial)" ? nil : parts[1]
                case "branch.head": status.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    if counts.count == 2 {
                        status.ahead = Int(counts[0].dropFirst()) ?? 0
                        status.behind = Int(counts[1].dropFirst()) ?? 0
                    }
                default: break
                }
                continue
            }

            switch record.first {
            case "1", "2":
                // 1 XY sub mH mI mW hH hI path
                // 2 XY sub mH mI mW hH hI Xscore path, followed by a separate origPath record
                let isRename = record.first == "2"
                let fieldCount = isRename ? 9 : 8
                let fields = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard fields.count == fieldCount + 1 else { continue }
                let xy = Array(fields[1])
                let path = String(fields[fieldCount])
                var originalPath: String?
                if isRename, index < records.count {
                    originalPath = records[index]
                    index += 1
                }
                if xy[0] != "." {
                    status.staged.append(GitChange(path: path, originalPath: originalPath, code: xy[0], area: .staged))
                }
                if xy[1] != "." {
                    status.unstaged.append(GitChange(path: path, originalPath: nil, code: xy[1], area: .unstaged))
                }
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                status.conflicted.append(GitChange(path: String(fields[10]), originalPath: nil, code: "U", area: .conflicted))
            case "?":
                status.unstaged.append(GitChange(path: String(record.dropFirst(2)), originalPath: nil, code: "?", area: .unstaged))
            default:
                break
            }
        }

        let byPath: (GitChange, GitChange) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.staged.sort(by: byPath)
        status.unstaged.sort(by: byPath)
        status.conflicted.sort(by: byPath)
        return status
    }
}

struct GitCommit: Identifiable, Equatable, Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let date: Date
    let subject: String
    let refs: [String]
    /// First parent first; two or more for a merge.
    var parents: [String] = []

    var id: String { hash }
    var isMerge: Bool { parents.count > 1 }

    static let logFormat = "%H%x1f%h%x1f%an%x1f%at%x1f%s%x1f%D%x1f%P%x1e"

    static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 7 else { return nil }
            return GitCommit(
                hash: String(fields[0]),
                shortHash: String(fields[1]),
                author: String(fields[2]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                subject: String(fields[4]),
                refs: fields[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                parents: fields[6].split(separator: " ").map(String.init)
            )
        }
    }
}

struct GitCommitDetail: Equatable {
    let commit: GitCommit
    let body: String
    let diff: ParsedDiff
}
