import SwiftUI

/// File and folder icons in color, by type: brand-colored badges for languages ("TS", "PY"),
/// tinted symbols for the rest, and folders colored by what they usually hold. One look across
/// the file tree, tabs, quick open, search and the git panel.
enum FileStyle: Equatable {
    /// A rounded square with a short label, in the language's colors.
    case badge(String, background: UInt32, foreground: UInt32)
    case symbol(String, color: UInt32?)

    static func of(_ url: URL) -> FileStyle {
        let name = url.lastPathComponent
        let lower = name.lowercased()

        // Whole names first: these mean something whatever their extension.
        switch lower {
        case "package.swift": return .symbol("shippingbox.fill", color: 0xF05138)
        case "package.json": return .symbol("shippingbox.fill", color: 0xCB3837)
        case "package.resolved", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "podfile.lock", "cargo.lock",
             "gemfile.lock", "composer.lock", "go.sum", "bun.lockb":
            return .symbol("lock.fill", color: 0x8B8F98)
        case "makefile", "gnumakefile": return .symbol("hammer.fill", color: 0xE37933)
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", ".dockerignore":
            return .symbol("shippingbox", color: 0x2496ED)
        case ".gitignore", ".gitattributes", ".gitmodules", ".gitkeep": return .symbol("arrow.triangle.branch", color: 0xF05033)
        case "license", "license.md", "license.txt", "licence": return .symbol("checkmark.seal.fill", color: 0xD4A72C)
        case "readme", "readme.md", "readme.txt": return .symbol("book.fill", color: 0x519ABA)
        case "claude.md", "agents.md": return .symbol("sparkle", color: 0xD97757)
        case "go.mod": return .badge("GO", background: 0x00ADD8, foreground: 0xFFFFFF)
        case "cargo.toml": return .badge("RS", background: 0xCE422B, foreground: 0xFFFFFF)
        case "gemfile", "rakefile": return .badge("RB", background: 0xCC342D, foreground: 0xFFFFFF)
        case "podfile": return .symbol("shippingbox", color: 0xEE3322)
        case ".editorconfig", ".prettierrc", ".eslintrc", ".swiftlint.yml", ".swift-format": return .symbol("slider.horizontal.3", color: 0x7B8794)
        default: break
        }
        if lower.hasPrefix(".env") { return .symbol("key.fill", color: 0xE3B341) }
        if lower.hasPrefix("dockerfile") { return .symbol("shippingbox", color: 0x2496ED) }

        switch url.pathExtension.lowercased() {
        // Languages: brand colors, as editors show them.
        case "swift": return .symbol("swift", color: 0xF05138)
        case "ts", "mts", "cts": return .badge("TS", background: 0x3178C6, foreground: 0xFFFFFF)
        case "tsx": return .badge("TSX", background: 0x3178C6, foreground: 0xFFFFFF)
        case "js", "mjs", "cjs": return .badge("JS", background: 0xF0D53A, foreground: 0x1F1F1F)
        case "jsx": return .badge("JSX", background: 0xF0D53A, foreground: 0x1F1F1F)
        case "py", "pyi": return .badge("PY", background: 0x3776AB, foreground: 0xFFD43B)
        case "ipynb": return .badge("NB", background: 0xF37626, foreground: 0xFFFFFF)
        case "go": return .badge("GO", background: 0x00ADD8, foreground: 0xFFFFFF)
        case "rs": return .badge("RS", background: 0xCE422B, foreground: 0xFFFFFF)
        case "rb", "erb": return .badge("RB", background: 0xCC342D, foreground: 0xFFFFFF)
        case "java": return .badge("JV", background: 0xE76F00, foreground: 0xFFFFFF)
        case "kt", "kts": return .badge("KT", background: 0x7F52FF, foreground: 0xFFFFFF)
        case "dart": return .badge("DT", background: 0x0175C2, foreground: 0xFFFFFF)
        case "php": return .badge("PHP", background: 0x777BB4, foreground: 0xFFFFFF)
        case "c": return .badge("C", background: 0x5C6BC0, foreground: 0xFFFFFF)
        case "h", "hh": return .badge("H", background: 0x8E99B0, foreground: 0xFFFFFF)
        case "cpp", "cc", "cxx", "hpp", "hxx": return .badge("C++", background: 0x00599C, foreground: 0xFFFFFF)
        case "m", "mm": return .badge("OC", background: 0x438EFF, foreground: 0xFFFFFF)
        case "cs": return .badge("C#", background: 0x68217A, foreground: 0xFFFFFF)
        case "lua": return .badge("LUA", background: 0x2C2D72, foreground: 0xFFFFFF)
        case "vue": return .badge("VUE", background: 0x42B883, foreground: 0x213547)
        case "svelte": return .badge("SV", background: 0xFF3E00, foreground: 0xFFFFFF)
        case "ex", "exs": return .badge("EX", background: 0x6E4A7E, foreground: 0xFFFFFF)
        case "zig": return .badge("ZIG", background: 0xF7A41D, foreground: 0x1F1F1F)
        case "scala": return .badge("SC", background: 0xDC322F, foreground: 0xFFFFFF)
        case "r": return .badge("R", background: 0x276DC3, foreground: 0xFFFFFF)
        case "graphql", "gql": return .badge("GQL", background: 0xE10098, foreground: 0xFFFFFF)
        case "proto": return .badge("PB", background: 0x4285F4, foreground: 0xFFFFFF)
        // Markup and styles.
        case "html", "htm": return .symbol("chevron.left.forwardslash.chevron.right", color: 0xE34F26)
        case "css": return .badge("#", background: 0x2965F1, foreground: 0xFFFFFF)
        case "scss", "sass": return .badge("#", background: 0xCF649A, foreground: 0xFFFFFF)
        case "less": return .badge("#", background: 0x1D365D, foreground: 0xFFFFFF)
        case "md", "markdown", "mdx": return .badge("M↓", background: 0x519ABA, foreground: 0xFFFFFF)
        case "svg": return .badge("SVG", background: 0xFFB13B, foreground: 0x1F1F1F)
        // Data and config.
        case "json", "jsonc", "json5": return .symbol("curlybraces", color: 0xE3B341)
        case "yaml", "yml": return .badge("YML", background: 0xA855F7, foreground: 0xFFFFFF)
        case "toml": return .badge("TML", background: 0x9C4221, foreground: 0xFFFFFF)
        case "xml", "plist", "xib", "storyboard", "entitlements": return .symbol("chevron.left.forwardslash.chevron.right", color: 0xE37933)
        case "sql", "sqlite", "db", "sqlite3": return .symbol("cylinder.split.1x2.fill", color: 0x00A8A8)
        case "csv", "tsv": return .symbol("tablecells.fill", color: 0x21A366)
        case "xlsx", "xls", "numbers": return .symbol("tablecells.fill", color: 0x21A366)
        case "ini", "cfg", "conf", "config", "properties": return .symbol("slider.horizontal.3", color: 0x7B8794)
        case "lock": return .symbol("lock.fill", color: 0x8B8F98)
        case "env": return .symbol("key.fill", color: 0xE3B341)
        // Scripts and builds.
        case "sh", "zsh", "bash", "fish", "command": return .symbol("terminal.fill", color: 0x4EAA25)
        case "ps1": return .symbol("terminal.fill", color: 0x2671BE)
        case "mk", "make", "cmake", "gradle": return .symbol("hammer.fill", color: 0xE37933)
        case "xcodeproj", "xcworkspace", "pbxproj", "xcscheme": return .symbol("hammer.fill", color: 0x1D8CF8)
        // Documents and media.
        case "txt", "rtf": return .symbol("doc.plaintext", color: nil)
        case "pdf": return .symbol("doc.richtext.fill", color: 0xE5483B)
        case "log": return .symbol("doc.text.magnifyingglass", color: 0x8B8F98)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "icns", "avif":
            return .symbol("photo.fill", color: 0xA074C4)
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": return .symbol("film.fill", color: 0xF778BA)
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return .symbol("waveform", color: 0xF778BA)
        case "ttf", "otf", "woff", "woff2": return .symbol("textformat", color: 0x7B8794)
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg": return .symbol("doc.zipper", color: 0x8B8F98)
        case "patch", "diff": return .symbol("plusminus", color: 0x3FB950)
        default: return .symbol("doc", color: nil)
        }
    }
}

/// The colored icon for a file, 16×16, for list rows, tabs and chips.
struct FileTypeIcon: View {
    let url: URL
    var size: CGFloat = 16

    init(_ url: URL, size: CGFloat = 16) {
        self.url = url
        self.size = size
    }

    init(path: String, size: CGFloat = 16) {
        self.init(URL(fileURLWithPath: path), size: size)
    }

    var body: some View {
        Group {
            switch FileStyle.of(url) {
            case .badge(let label, let background, let foreground):
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color(hex: background))
                    .frame(width: size * 0.86, height: size * 0.86)
                    .overlay {
                        Text(label)
                            .font(.system(size: size * (label.count > 2 ? 0.36 : 0.46), weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(hex: foreground))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .padding(.horizontal, 0.5)
                    }
            case .symbol(let name, let color):
                Image(systemName: name)
                    .font(.system(size: size * 0.8, weight: .medium))
                    .foregroundStyle(color.map { AnyShapeStyle(Color(hex: $0)) } ?? AnyShapeStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A folder in the color of what it usually holds: sources blue, tests green, build output grey.
struct FolderIcon: View {
    let name: String
    var isOpen = false
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: size * 0.82, weight: .medium))
            .foregroundStyle(Color(hex: Self.color(for: name)).opacity(Self.isGenerated(name) ? 0.55 : 1))
            .overlay(alignment: .bottomTrailing) {
                if let mark = Self.mark(for: name) {
                    Image(systemName: mark)
                        .font(.system(size: size * 0.38, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: -size * 0.12, y: -size * 0.1)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func color(for name: String) -> UInt32 {
        switch name.lowercased() {
        case "sources", "source", "src", "lib", "app", "apps", "packages", "pkg", "internal", "cmd": 0x4C8DF6
        case "tests", "test", "__tests__", "spec", "specs", "uitests", "e2e": 0x3FB950
        case "docs", "doc", "documentation": 0x2BB3C0
        case "assets", "images", "img", "icons", "public", "static", "resources", "media", "fonts": 0xA074C4
        case "views", "components", "ui", "screens", "pages", "layouts", "widgets": 0x39C5CF
        case "model", "models", "database", "db", "data", "migrations", "schema", "entities": 0xE3B341
        case "scripts", "bin", "tools", "tasks": 0x4EAA25
        case "support", "config", "configs", ".config", "settings", "env": 0x7B8794
        case ".git", ".github", ".gitlab", ".husky": 0xF05033
        case ".claude": 0xD97757
        case ".vscode", ".idea", ".xcode": 0x1D8CF8
        case "api", "server", "backend", "routes", "controllers", "services": 0xF778BA
        default: isGenerated(name) ? 0x8B8F98 : 0x5AA2E8
        }
    }

    /// Build output and dependencies: drawn faint, nobody edits them.
    static func isGenerated(_ name: String) -> Bool {
        ["build", ".build", "dist", "out", "target", "deriveddata", "node_modules", "pods", "vendor", ".next",
         ".nuxt", ".dart_tool", ".gradle", "__pycache__", ".venv", "venv", "coverage", ".cache", ".turbo"]
            .contains(name.lowercased())
    }

    /// A small glyph on the folder for the few that are worth telling apart at a glance.
    static func mark(for name: String) -> String? {
        switch name.lowercased() {
        case "tests", "test", "__tests__", "spec", "specs", "uitests", "e2e": "checkmark"
        case ".git", ".github", ".gitlab": "arrow.triangle.branch"
        case ".claude": "sparkle"
        default: nil
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
