import Foundation

/// Git worktrees where agents work on a board card each: `<project>/.tezgah/worktrees/<name>`
/// on branch `tezgah/<name>`, started from the project's current commit. `.tezgah/` is ignored
/// through the repository's own `info/exclude`, so nothing in the project changes.
enum Worktrees {
    static let folder = ".tezgah/worktrees"
    static let branchPrefix = "tezgah/"

    struct Created: Equatable {
        let branch: String
        let url: URL
    }

    /// Creates a worktree and its branch for a card, named after its title.
    static func create(named title: String, projectURL: URL, root: URL) async throws -> Created {
        try await ignoreTezgahFolder(root: root)
        let titleSlug = slug(title)
        let base = titleSlug.isEmpty ? "is" : titleSlug
        let folder = projectURL.appendingPathComponent(Self.folder, isDirectory: true)
        let branches = Set(try await Git.run(["branch", "--list", "--format=%(refname:short)", branchPrefix + "*"], in: root).lines)
        var name = base
        var number = 2
        while branches.contains(branchPrefix + name) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(number)"
            number += 1
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        _ = try await Git.run(["worktree", "add", "-b", branchPrefix + name, url.path, "HEAD"], in: root)
        return Created(branch: branchPrefix + name, url: url)
    }

    /// "Giriş ekranı: şifre sıfırlama" → "giris-ekrani-sifre-sifirlama"
    static func slug(_ title: String) -> String {
        let latin = title
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var slug = ""
        for character in latin {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        if slug.count > 40 {
            slug = String(slug.prefix(40))
            // End at a word boundary when there is one.
            if let dash = slug.lastIndex(of: "-"), slug.distance(from: slug.startIndex, to: dash) > 20 {
                slug = String(slug[..<dash])
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// Adds `.tezgah/` to the repository's `info/exclude`, shared by all its worktrees.
    static func ignoreTezgahFolder(root: URL) async throws {
        let commonDirectory = try await Git.run(["rev-parse", "--git-common-dir"], in: root).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let common = commonDirectory.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirectory, isDirectory: true)
            : root.appendingPathComponent(commonDirectory, isDirectory: true)
        let info = common.appendingPathComponent("info", isDirectory: true)
        let exclude = info.appendingPathComponent("exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(".tezgah/") else { return }
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try Data((current + separator + "# Tezgah: agents' worktrees\n.tezgah/\n").utf8).write(to: exclude)
    }

    /// Changes not committed in a worktree, untracked files included.
    static func hasUncommittedChanges(at url: URL) async throws -> Bool {
        !(try await Git.run(["status", "--porcelain"], in: url).text.isEmpty)
    }

    /// Files that merging the branch into the project's checked-out commit would conflict in,
    /// worked out without touching the checkout; empty if it merges cleanly, nil if git can't say.
    static func conflicts(merging branch: String, root: URL) async -> [String]? {
        guard let output = try? await Git.run(["merge-tree", "--write-tree", "--name-only", "HEAD", branch], in: root, allowedExitCodes: [0, 1]) else {
            return nil
        }
        guard output.exitCode == 1 else { return [] }
        // The tree's id, then the conflicted files up to a blank line, then git's messages.
        return Array(output.text.components(separatedBy: "\n").dropFirst().prefix { !$0.isEmpty })
    }

    /// Merges a branch into whatever the project has checked out. A merge that stops (conflicts,
    /// local changes in the way) is undone, so the project is left as it was.
    static func merge(branch: String, root: URL) async throws {
        do {
            _ = try await Git.run(["merge", "--no-edit", branch], in: root)
        } catch {
            _ = try? await Git.run(["merge", "--abort"], in: root)
            throw error
        }
    }

    /// Removes a worktree and its branch. `force` also throws away uncommitted and unmerged work.
    static func remove(_ url: URL, branch: String, root: URL, force: Bool) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try await Git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [url.path], in: root)
        } else {
            // Deleted by hand: let git forget it.
            _ = try await Git.run(["worktree", "prune"], in: root)
        }
        _ = try await Git.run(["branch", force ? "-D" : "-d", branch], in: root)
    }
}
