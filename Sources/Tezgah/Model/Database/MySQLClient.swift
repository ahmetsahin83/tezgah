import Foundation
import MySQLNIO

/// MySQL and MariaDB through MySQLNIO.
actor MySQLClient: DatabaseClient {
    private let connection: MySQLConnection
    /// Whether the user picked a database; without one the browser lists every non-system schema.
    private let hasDatabase: Bool
    private let config: DatabaseConfig
    private let password: String?
    /// For KILL QUERY from a second connection.
    private var connectionID: Int?

    private init(connection: MySQLConnection, config: DatabaseConfig, password: String?) {
        self.connection = connection
        self.hasDatabase = !config.database.isEmpty
        self.config = config
        self.password = password
    }

    static func connect(_ config: DatabaseConfig, password: String?) async throws -> MySQLClient {
        let client = MySQLClient(connection: try await open(config, password: password), config: config, password: password)
        await client.loadConnectionID()
        return client
    }

    private func loadConnectionID() async {
        let result = try? await execute("SELECT CONNECTION_ID()")
        if let cell = result?.rows.first?.first, let value = cell { connectionID = Int(value) }
    }

    func cancel() async {
        guard let connectionID, let other = try? await Self.open(config, password: password) else { return }
        _ = try? await other.simpleQuery("KILL QUERY \(connectionID)").get()
        try? await other.close().get()
    }

    private static func open(_ config: DatabaseConfig, password: String?) async throws -> MySQLConnection {
        var logger = Logger(label: "tezgah.mysql")
        logger.logLevel = .error
        let address: SocketAddress
        do {
            address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.effectivePort)
        } catch {
            throw DatabaseError(message: "“\(config.host)” adresi çözümlenemedi.")
        }

        func attempt(_ tls: TLSConfiguration?) async throws -> MySQLConnection {
            try await MySQLConnection.connect(
                to: address,
                username: config.user,
                database: config.database,
                password: password,
                tlsConfiguration: tls,
                serverHostname: config.host,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        }

        do {
            let connection: MySQLConnection
            switch config.tls {
            case .disable:
                connection = try await attempt(nil)
            case .require:
                connection = try await attempt(.makeClientConfiguration())
            case .prefer:
                var unverified = TLSConfiguration.makeClientConfiguration()
                unverified.certificateVerification = .none
                do {
                    connection = try await attempt(unverified)
                } catch {
                    // The server may not offer TLS at all.
                    connection = try await attempt(nil)
                }
            }
            return connection
        } catch {
            throw DatabaseError(message: describe(error))
        }
    }

    func execute(_ sql: String) async throws -> QueryResult {
        do {
            return SQLText.returnsRows(sql) ? try await rows(sql) : try await command(sql)
        } catch {
            let message = Self.describe(error)
            throw DatabaseError(message: message, position: Self.position(in: sql, message: message))
        }
    }

    /// The text protocol: every value arrives as the text MySQL would print.
    private func rows(_ sql: String) async throws -> QueryResult {
        let box = LockedValue(QueryResult())
        try await connection.simpleQuery(sql) { row in
            box.withLockedValue { result in
                if result.columns.isEmpty { result.columns = row.columnDefinitions.map(\.name) }
                guard result.rows.count < DatabaseLimits.maxRows else {
                    result.isTruncated = true
                    return
                }
                result.rows.append(zip(row.columnDefinitions, row.values).map { column, value in
                    Self.text(value, column: column)
                })
            }
        }.get()
        return box.withLockedValue { $0 }
    }

    /// Statements without rows go through the prepared-statement protocol, which reports affected rows.
    private func command(_ sql: String) async throws -> QueryResult {
        let affected = LockedValue<Int?>(nil)
        do {
            _ = try await connection.query(sql, onMetadata: { metadata in
                affected.withLockedValue { $0 = Int(metadata.affectedRows) }
            }).get()
            return QueryResult(affectedRows: affected.withLockedValue { $0 })
        } catch MySQLError.server(let packet) where packet.errorCode == .UNSUPPORTED_PS {
            // Some statements (certain DDL, LOCK TABLES…) cannot be prepared.
            _ = try await connection.simpleQuery(sql).get()
            return QueryResult()
        }
    }

    func tables() async throws -> [SchemaTable] {
        let result = try await execute("""
            SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE \(schemaFilter) ORDER BY TABLE_SCHEMA, TABLE_NAME
            """)
        return result.rows.map { SchemaTable(schema: $0[0] ?? "", name: $0[1] ?? "", isView: $0[2] == "VIEW") }
    }

    func columns(of table: SchemaTable) async throws -> QueryResult {
        try await execute("""
            SELECT COLUMN_NAME AS `Kolon`, COLUMN_TYPE AS `Tip`,
                   IF(IS_NULLABLE = 'YES', 'evet', 'hayır') AS `Boş olabilir`,
                   COLUMN_DEFAULT AS `Varsayılan`,
                   NULLIF(CONCAT_WS(' ', CASE COLUMN_KEY WHEN 'PRI' THEN 'PRIMARY' WHEN 'UNI' THEN 'UNIQUE' WHEN 'MUL' THEN 'INDEX' END,
                                    NULLIF(EXTRA, '')), '') AS `Anahtar`
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(SQLText.literal(table.schema)) AND TABLE_NAME = \(SQLText.literal(table.name))
            ORDER BY ORDINAL_POSITION
            """)
    }

    func indexes(of table: SchemaTable) async throws -> QueryResult {
        try await execute("""
            SELECT INDEX_NAME AS `İndeks`,
                   CONCAT(IF(NON_UNIQUE = 0, 'UNIQUE ', ''), INDEX_TYPE, ' (',
                          GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', '), ')') AS `Tanım`
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(SQLText.literal(table.schema)) AND TABLE_NAME = \(SQLText.literal(table.name))
            GROUP BY INDEX_NAME, NON_UNIQUE, INDEX_TYPE
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME
            """)
    }

    private var schemaFilter: String {
        hasDatabase
            ? "TABLE_SCHEMA = DATABASE()"
            : "TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')"
    }

    func allColumns() async throws -> [SchemaColumn] {
        let result = try await execute("""
            SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY
            FROM information_schema.COLUMNS WHERE \(schemaFilter)
            ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
            """)
        return result.rows.map {
            SchemaColumn(schema: $0[0] ?? "", table: $0[1] ?? "", name: $0[2] ?? "", type: $0[3] ?? "",
                         isNullable: SQLText.flag($0[4]), isPrimaryKey: $0[5] == "PRI")
        }
    }

    func foreignKeys() async throws -> [ForeignKey] {
        let result = try await execute("""
            SELECT CONSTRAINT_NAME, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
                   REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE REFERENCED_TABLE_NAME IS NOT NULL AND \(schemaFilter)
            ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
            """)
        return ForeignKey.grouping(result.rows)
    }

    nonisolated func selectAllSQL(from table: SchemaTable, limit: Int) -> String {
        "SELECT * FROM \(Self.identifier(table.schema)).\(Self.identifier(table.name)) LIMIT \(limit);"
    }

    func close() async {
        try? await connection.close().get()
    }

    static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private static func text(_ value: ByteBuffer?, column: MySQLProtocol.ColumnDefinition41) -> String? {
        guard var value else { return nil }
        let count = value.readableBytes
        let bytes = value.readBytes(length: count) ?? []
        // Binary columns (BLOB, BINARY, VARBINARY) use the "binary" character set, number 63.
        if column.characterSet == .binary, ![.newdecimal, .decimal, .longlong, .long, .short, .tiny, .int24, .double, .float,
                                              .date, .datetime, .timestamp, .time, .year].contains(column.columnType) {
            if let text = String(bytes: bytes, encoding: .utf8), !text.contains("\0") { return SQLText.shorten(text) }
            return DatabaseValueText.blob(Data(bytes.prefix(64)), totalCount: count)
        }
        return SQLText.shorten(String(decoding: bytes, as: UTF8.self))
    }

    /// MySQL says "… near 'FORM users' at line 2"; find that spot in the statement.
    static func position(in sql: String, message: String) -> Int? {
        guard let match = message.range(of: #"near '(.*)' at line (\d+)"#, options: [.regularExpression, .backwards]) else { return nil }
        let found = String(message[match])
        guard let lineText = found.range(of: #"\d+$"#, options: .regularExpression), let line = Int(found[lineText]),
              let quoteStart = found.firstIndex(of: "'"), let quoteEnd = found.range(of: "' at line", options: .backwards) else { return nil }
        let near = String(found[found.index(after: quoteStart)..<quoteEnd.lowerBound])
        let text = sql as NSString
        var lineStart = 0
        for _ in 1..<max(line, 1) {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: lineStart, length: text.length - lineStart))
            guard newline.location != NSNotFound else { break }
            lineStart = NSMaxRange(newline)
        }
        guard !near.isEmpty else { return text.length }
        let probe = String(near.prefix(30))
        let hit = text.range(of: probe, options: [], range: NSRange(location: lineStart, length: text.length - lineStart))
        return hit.location != NSNotFound ? hit.location : lineStart
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case MySQLError.server(let packet):
            return "\(packet.errorMessage) (\(packet.errorCode.rawValue))"
        case MySQLError.secureConnectionRequired:
            return "Sunucu bu kullanıcı için şifreli bağlantı istiyor. TLS ayarını “Varsa kullan” ya da “Zorunlu” yap."
        case MySQLError.unsupportedAuthPlugin(let name):
            return "Sunucunun kimlik doğrulama yöntemi (\(name)) desteklenmiyor."
        case MySQLError.closed:
            return "Bağlantı kapandı."
        case let error as MySQLError:
            return error.message
        case let error as DatabaseError:
            return error.message
        case let error as IOError:
            return "Sunucuya bağlanılamadı: \(error.description)"
        default:
            return String(describing: error)
        }
    }
}
