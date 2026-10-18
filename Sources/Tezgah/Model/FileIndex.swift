import Foundation

struct FileEntry: Sendable, Identifiable {
    /// Path relative to the project folder.
    let path: String
    /// UTF-16 of `path`, and its lowercased form with the same length, for matching.
    let units: [UInt16]
    let lowered: [UInt16]
    /// UTF-16 offset where the file name begins.
    let nameStart: Int
    /// Lock files and generated code, which should lose ties against hand-written files.
    let isGenerated: Bool

    var id: String { path }

    init(path: String) {
        self.path = path
        units = Array(path.utf16)
        lowered = FuzzyMatcher.lowercased(units)
        nameStart = (units.lastIndex(of: 0x2F /* / */) ?? -1) + 1
        isGenerated = Self.generatedSuffixes.contains { path.hasSuffix($0) }
    }

    private static let generatedSuffixes = [".lock", "-lock.json", "-lock.yaml", ".g.dart", ".freezed.dart", ".pb.go", ".min.js"]
}

/// The list of files in a project, for quick open.
@MainActor
final class FileIndex {
    nonisolated static let maxFiles = 100_000
    /// Skipped when walking folders that are not git repositories.
    nonisolated static let skippedFolders: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".dart_tool", ".gradle",
        ".idea", ".next", ".nuxt", ".turbo", ".cache", ".venv", "venv", "__pycache__", "dist", "target", ".tezgah",
    ]

    let rootURL: URL
    private(set) var entries: [FileEntry] = []
    private var loading: Task<Void, Never>?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func refresh() async {
        if let loading {
            await loading.value
            return
        }
        let root = rootURL
        let task = Task {
            entries = await Task.detached(priority: .userInitiated) { await FileIndex.load(root) }.value
        }
        loading = task
        await task.value
        loading = nil
    }

    nonisolated static func load(_ root: URL) async -> [FileEntry] {
        if let paths = try? await gitFiles(in: root) {
            return paths.prefix(maxFiles).map(FileEntry.init)
        }
        return walk(root)
    }

    /// Tracked and untracked-but-not-ignored files, so .gitignore is respected.
    nonisolated private static func gitFiles(in root: URL) async throws -> [String] {
        let listed = try await Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        let deleted = try await Git.run(["ls-files", "-z", "--deleted"], in: root)
        let deletedPaths = Set(paths(in: deleted.stdout))
        var seen = Set<String>()
        return paths(in: listed.stdout).filter { !deletedPaths.contains($0) && seen.insert($0).inserted }
    }

    nonisolated private static func paths(in data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    nonisolated private static func walk(_ root: URL) -> [FileEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.producesRelativePathURLs]
        ) else { return [] }

        var entries: [FileEntry] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            entries.append(FileEntry(path: url.relativePath))
            if entries.count >= maxFiles { break }
        }
        return entries
    }
}

/// Subsequence matching with VS Code-like ranking: file name hits, word starts and
/// consecutive characters score higher.
enum FuzzyMatcher {
    struct Match: Sendable {
        let score: Int
        /// UTF-16 offsets of the matched characters in the path.
        let positions: [Int]
    }

    static func search(_ query: String, in entries: [FileEntry], limit: Int = 60) -> [(entry: FileEntry, match: Match)] {
        let needle = lowercased(Array(query.replacingOccurrences(of: " ", with: "").utf16))
        guard !needle.isEmpty else { return [] }

        var found: [(entry: FileEntry, match: Match)] = []
        for (index, entry) in entries.enumerated() {
            if index % 4096 == 0, Task.isCancelled { return [] }
            if let match = match(needle, in: entry) {
                found.append((entry, match))
            }
        }
        found.sort {
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            if $0.entry.units.count != $1.entry.units.count { return $0.entry.units.count < $1.entry.units.count }
            return $0.entry.path < $1.entry.path
        }
        return Array(found.prefix(limit))
    }

    static func match(_ needle: [UInt16], in entry: FileEntry) -> Match? {
        let haystack = entry.lowered
        guard !needle.isEmpty, needle.count <= haystack.count,
              let leftmost = greedy(needle, in: haystack, from: 0) else { return nil }

        // Try a few alignments and keep the best: leftmost, inside the file name only,
        // and the last contiguous occurrence.
        var best = Match(score: score(leftmost, in: entry), positions: leftmost)
        for candidate in [greedy(needle, in: haystack, from: entry.nameStart), lastSubstring(needle, in: haystack)] {
            guard let candidate else { continue }
            let candidateScore = score(candidate, in: entry)
            if candidateScore > best.score {
                best = Match(score: candidateScore, positions: candidate)
            }
        }
        return best
    }

    static func lowercased(_ units: [UInt16]) -> [UInt16] {
        units.map { unit in
            switch unit {
            case 0x41...0x5A: return unit + 0x20
            case 0..<0x80: return unit
            default:
                // Keep the length unchanged; characters whose lowercase form is longer stay as they are.
                guard let scalar = Unicode.Scalar(unit) else { return unit }
                let lower = String(Character(scalar)).lowercased().utf16
                return lower.count == 1 ? lower.first! : unit
            }
        }
    }

    private static func greedy(_ needle: [UInt16], in haystack: [UInt16], from start: Int) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var n = 0
        var h = start
        while n < needle.count, h < haystack.count {
            if needle[n] == haystack[h] {
                positions.append(h)
                n += 1
            }
            h += 1
        }
        return n == needle.count ? positions : nil
    }

    private static func lastSubstring(_ needle: [UInt16], in haystack: [UInt16]) -> [Int]? {
        var start = haystack.count - needle.count
        while start >= 0 {
            if haystack[start..<start + needle.count].elementsEqual(needle) {
                return Array(start..<start + needle.count)
            }
            start -= 1
        }
        return nil
    }

    private static func score(_ positions: [Int], in entry: FileEntry) -> Int {
        var score = 0
        var previous = -2
        for position in positions {
            score += 1
            if position == previous + 1 { score += 6 }
            if isWordStart(position, in: entry.units) { score += 8 }
            if position >= entry.nameStart { score += 3 }
            previous = position
        }
        let span = positions.last! - positions.first! + 1
        score -= span - positions.count // gaps between matched characters
        if positions.first == entry.nameStart { score += 15 }
        score -= entry.units.count / 8 // shorter paths win ties
        if entry.isGenerated { score -= 4 }
        return score
    }

    private static func isWordStart(_ index: Int, in units: [UInt16]) -> Bool {
        guard index > 0 else { return true }
        let previous = units[index - 1]
        switch previous {
        case 0x2F, 0x5F, 0x2D, 0x2E, 0x20: // / _ - . space
            return true
        default:
            // camelCase hump: lowercase followed by uppercase
            return (0x41...0x5A).contains(units[index]) && (0x61...0x7A).contains(previous)
        }
    }
}
