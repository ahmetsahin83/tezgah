import Foundation

/// Projects that share a parent folder, e.g. ~/bee/beecons and ~/bee/recetem form the "bee" group.
struct ProjectGroup: Identifiable {
    let url: URL
    let displayName: String
    let projects: [Project]

    var id: String { url.path }
}

enum ProjectDetector {
    private static let markerFiles = [
        ".git", "package.json", "pubspec.yaml", "Package.swift", "go.mod", "Cargo.toml",
        "pyproject.toml", "requirements.txt", "composer.json", "Gemfile", "build.gradle",
        "build.gradle.kts", "pom.xml", "Podfile", "Makefile",
    ]
    private static let markerExtensions: Set<String> = ["xcodeproj", "xcworkspace"]

    static func isProject(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        if markerFiles.contains(where: { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return true
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { markerExtensions.contains(($0 as NSString).pathExtension) }
    }

    /// Direct sub-folders of `url` that look like projects, sorted by name.
    static func projects(in url: URL) -> [URL] {
        let subfolders = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return subfolders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter(isProject)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
