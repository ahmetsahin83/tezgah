import Foundation
import Security

/// A saved database connection. The password is kept in the Keychain, never in workspace.json.
struct DatabaseConfig: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case postgres, mysql, sqlite

        var title: String {
            switch self {
            case .postgres: "PostgreSQL"
            case .mysql: "MySQL / MariaDB"
            case .sqlite: "SQLite"
            }
        }

        var defaultPort: Int? {
            switch self {
            case .postgres: 5432
            case .mysql: 3306
            case .sqlite: nil
            }
        }
    }

    enum TLSMode: String, Codable, CaseIterable, Sendable {
        /// Encrypt when the server supports it, without checking its certificate (typical for local and dev servers).
        case prefer
        /// Encrypt and verify the certificate.
        case require
        case disable

        var title: String {
            switch self {
            case .prefer: "Varsa kullan"
            case .require: "Zorunlu (sertifika doğrulanır)"
            case .disable: "Kapalı"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var host = "localhost"
    var port: Int?
    var user = ""
    var database = ""
    /// SQLite file; relative paths are resolved against the project folder.
    var path = ""
    var tls = TLSMode.prefer
    /// Connect through `ssh -L` to a server that is only reachable from another machine.
    var ssh: SSHSettings?
    /// Off: statements run inside a transaction that stays open until Commit or Rollback. Nil means on.
    var autoCommit: Bool?

    var effectivePort: Int { port ?? kind.defaultPort ?? 0 }

    /// "user@host:5432/db" or the SQLite file name, for lists.
    var summary: String {
        switch kind {
        case .sqlite:
            return (path as NSString).lastPathComponent
        case .postgres, .mysql:
            var text = user.isEmpty ? "" : "\(user)@"
            text += "\(host):\(effectivePort)"
            if !database.isEmpty { text += "/\(database)" }
            if let ssh { text += " (SSH: \(ssh.host))" }
            return text
        }
    }

    func fileURL(relativeTo project: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : project.appendingPathComponent(expanded)
    }
}

/// The machine an SSH tunnel goes through. Authentication uses keys or ssh-agent, like `ssh` in a terminal;
/// host aliases from ~/.ssh/config work too.
struct SSHSettings: Codable, Hashable, Sendable {
    var host = ""
    var port: Int?
    var user = ""
    /// Private key file; empty means ssh's defaults and the agent.
    var identityFile = ""

    var summary: String {
        (user.isEmpty ? "" : "\(user)@") + host + (port.map { ":\($0)" } ?? "")
    }
}

// MARK: Connection URLs

extension DatabaseConfig {
    /// A configuration and password from a URL like postgres://user:pass@host:5432/db,
    /// mysql://…, mariadb://… or sqlite:path/to/file.db.
    static func parse(url text: String, name: String? = nil) -> (config: DatabaseConfig, password: String?)? {
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()

        if scheme == "sqlite" || scheme == "sqlite3" || scheme == "file" {
            var path = String(text[text.index(after: colon)...])
            if path.hasPrefix("//") { path.removeFirst(2) }
            if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
            guard !path.isEmpty else { return nil }
            let config = DatabaseConfig(name: name ?? (path as NSString).lastPathComponent, kind: .sqlite, path: path)
            return (config, nil)
        }

        let kind: Kind
        switch scheme {
        case "postgres", "postgresql", "pgsql": kind = .postgres
        case "mysql", "mysql2", "mariadb", "mysqlx": kind = .mysql
        default: return nil
        }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        var config = DatabaseConfig(name: name ?? host, kind: kind)
        config.host = host
        config.port = components.port
        config.user = components.user?.removingPercentEncoding ?? components.user ?? ""
        config.database = String(components.path.drop { $0 == "/" })
        let query = components.queryItems ?? []
        switch query.first(where: { $0.name == "sslmode" || $0.name == "ssl-mode" || $0.name == "ssl" })?.value?.lowercased() {
        case "disable", "false", "disabled": config.tls = .disable
        case "require", "verify-ca", "verify-full", "true", "required": config.tls = .require
        default: break
        }
        if name == nil {
            config.name = config.database.isEmpty ? host : config.database
        }
        let password = components.password.map { $0.removingPercentEncoding ?? $0 }
        return (config, password)
    }

    /// Connection URLs found in the project's .env files (DATABASE_URL and friends).
    static func fromEnvironmentFiles(in project: URL) -> [(source: String, config: DatabaseConfig, password: String?)] {
        let names = [".env", ".env.local", ".env.development", ".env.development.local"]
        var found: [(String, DatabaseConfig, String?)] = []
        for name in names {
            guard let text = try? String(contentsOf: project.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                var line = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("export ") { line.removeFirst("export ".count) }
                guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equals)...])
                guard let (config, password) = parse(url: value, name: key == "DATABASE_URL" ? nil : key) else { continue }
                if config.kind == .sqlite, !value.contains(":") { continue }
                found.append(("\(name) · \(key)", config, password))
            }
        }
        return found
    }

    /// SQLite files in the project, from its file list.
    static func sqliteFiles(in entries: [FileEntry]) -> [String] {
        let extensions: Set<String> = ["sqlite", "sqlite3", "db", "db3"]
        return entries.map(\.path).filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }
}

// MARK: Keychain

enum DatabasePasswords {
    private static let service = "dev.ahmetsahin.tezgah.database"
    /// Read once per launch. Each Keychain read may ask for the login password (always so for an app
    /// signed ad hoc, which the Keychain sees as a new app after every build), and an agent's
    /// session reconnects often.
    nonisolated(unsafe) private static var cache: [UUID: String?] = [:]
    private static let lock = NSLock()

    static func password(for id: UUID) -> String? {
        if let cached = lock.withLock({ cache[id] }) { return cached }
        let password = readPassword(for: id)
        lock.withLock { cache[id] = password }
        return password
    }

    private static func readPassword(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(item as CFDictionary)
        lock.withLock { cache[id] = password?.isEmpty == false ? password : nil }
        guard let password, !password.isEmpty else { return }
        var added = item
        added[kSecValueData as String] = Data(password.utf8)
        added[kSecAttrLabel as String] = "Tezgah veritabanı parolası"
        let status = SecItemAdd(added as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Tezgah: could not save database password: \(status)")
        }
    }
}
