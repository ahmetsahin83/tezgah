import Foundation
import PostgresNIO

/// PostgreSQL through PostgresNIO.
actor PostgresClient: DatabaseClient {
    private let connection: PostgresConnection
    private let logger: Logger
    private let config: DatabaseConfig
    private let password: String?
    /// The server process running our queries, for cancelling them from a second connection.
    private var backendPID: Int?

    private init(connection: PostgresConnection, logger: Logger, config: DatabaseConfig, password: String?) {
        self.connection = connection
        self.logger = logger
        self.config = config
        self.password = password
    }

    static func connect(_ config: DatabaseConfig, password: String?) async throws -> PostgresClient {
        let (connection, logger) = try await open(config, password: password)
        let client = PostgresClient(connection: connection, logger: logger, config: config, password: password)
        await client.loadBackendPID()
        return client
    }

    private func loadBackendPID() async {
        let result = try? await execute("SELECT pg_backend_pid()")
        if let cell = result?.rows.first?.first, let value = cell { backendPID = Int(value) }
    }

    private static func open(_ config: DatabaseConfig, password: String?) async throws -> (PostgresConnection, Logger) {
        var logger = Logger(label: "tezgah.postgres")
        logger.logLevel = .error

        let tls: PostgresConnection.Configuration.TLS
        switch config.tls {
        case .disable:
            tls = .disable
        case .prefer:
            var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
            tlsConfiguration.certificateVerification = .none
            tls = .prefer(try NIOSSLContext(configuration: tlsConfiguration))
        case .require:
            tls = .require(try NIOSSLContext(configuration: .makeClientConfiguration()))
        }
        let configuration = PostgresConnection.Configuration(
            host: config.host,
            port: config.effectivePort,
            username: config.user,
            password: password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
        do {
            let connection = try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
            return (connection, logger)
        } catch {
            throw DatabaseError(message: describe(error))
        }
    }

    func execute(_ sql: String) async throws -> QueryResult {
        do {
            return SQLText.returnsRows(sql) ? try await rows(sql) : try await command(sql)
        } catch {
            throw DatabaseError(message: Self.describe(error), position: Self.position(of: error, in: sql))
        }
    }

    func cancel() async {
        guard let backendPID else { return }
        // A cancel request goes over a separate connection, like psql's Ctrl-C.
        guard let (other, _) = try? await Self.open(config, password: password) else { return }
        _ = try? await other.query(PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(backendPID))"), logger: logger)
            .collect()
        try? await other.close()
    }

    /// Row-returning statements: column names arrive even for an empty result.
    private func rows(_ sql: String) async throws -> QueryResult {
        let sequence = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var result = QueryResult(columns: sequence.columns.map(\.name))
        for try await row in sequence {
            if result.rows.count >= DatabaseLimits.maxRows {
                result.isTruncated = true
                break
            }
            result.rows.append(row.map { cell in
                PostgresValueText.text(cell.bytes, type: cell.dataType, format: cell.format)
            })
        }
        return result
    }

    /// Other statements, through the API that reports the command tag ("UPDATE 3").
    private func command(_ sql: String) async throws -> QueryResult {
        let box = LockedValue<(rows: Int?, columns: [String], values: [[String?]])>((nil, [], []))
        try await connection.query(sql, onMetadata: { metadata in
            box.withLockedValue { $0.rows = metadata.rows }
        }, onRow: { row in
            // A statement that unexpectedly returns rows (e.g. a function call): show them anyway.
            box.withLockedValue { state in
                guard state.values.count < DatabaseLimits.maxRows else { return }
                let cells = Array(row)
                if state.columns.isEmpty { state.columns = cells.map(\.columnName) }
                state.values.append(cells.map { PostgresValueText.text($0.bytes, type: $0.dataType, format: $0.format) })
            }
        }).get()
        let state = box.withLockedValue { $0 }
        return QueryResult(columns: state.columns, rows: state.values, affectedRows: state.columns.isEmpty ? state.rows : nil)
    }

    func tables() async throws -> [SchemaTable] {
        let result = try await execute("""
            SELECT table_schema::text, table_name::text, table_type::text
            FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_schema NOT LIKE 'pg_toast%'
            ORDER BY table_schema = 'public' DESC, table_schema, table_name
            """)
        return result.rows.map { SchemaTable(schema: $0[0] ?? "", name: $0[1] ?? "", isView: $0[2] == "VIEW") }
    }

    func columns(of table: SchemaTable) async throws -> QueryResult {
        try await execute("""
            SELECT c.column_name::text AS "Kolon",
                   CASE WHEN c.data_type = 'USER-DEFINED' THEN c.udt_name ELSE c.data_type END::text
                       || COALESCE('(' || c.character_maximum_length || ')', '') AS "Tip",
                   CASE c.is_nullable WHEN 'YES' THEN 'evet' ELSE 'hayır' END AS "Boş olabilir",
                   c.column_default::text AS "Varsayılan",
                   (SELECT string_agg(tc.constraint_type::text, ', ')
                      FROM information_schema.key_column_usage k
                      JOIN information_schema.table_constraints tc
                        ON tc.constraint_name = k.constraint_name AND tc.table_schema = k.table_schema
                     WHERE k.table_schema = c.table_schema AND k.table_name = c.table_name
                       AND k.column_name = c.column_name) AS "Anahtar"
            FROM information_schema.columns c
            WHERE c.table_schema = \(SQLText.literal(table.schema)) AND c.table_name = \(SQLText.literal(table.name))
            ORDER BY c.ordinal_position
            """)
    }

    func indexes(of table: SchemaTable) async throws -> QueryResult {
        try await execute("""
            SELECT indexname::text AS "İndeks", indexdef AS "Tanım" FROM pg_indexes
            WHERE schemaname = \(SQLText.literal(table.schema)) AND tablename = \(SQLText.literal(table.name))
            ORDER BY indexname
            """)
    }

    func allColumns() async throws -> [SchemaColumn] {
        let result = try await execute("""
            SELECT n.nspname::text, c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod),
                   (NOT a.attnotnull)::text, COALESCE(a.attnum = ANY(i.indkey), false)::text
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
            WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
              AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY n.nspname, c.relname, a.attnum
            """)
        return result.rows.map {
            SchemaColumn(schema: $0[0] ?? "", table: $0[1] ?? "", name: $0[2] ?? "", type: $0[3] ?? "",
                         isNullable: SQLText.flag($0[4]), isPrimaryKey: SQLText.flag($0[5]))
        }
    }

    func foreignKeys() async throws -> [ForeignKey] {
        let result = try await execute("""
            SELECT k.conname::text, n.nspname::text, c.relname::text, a.attname::text,
                   fn.nspname::text, fc.relname::text, fa.attname::text
            FROM pg_constraint k
            JOIN pg_class c ON c.oid = k.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_class fc ON fc.oid = k.confrelid
            JOIN pg_namespace fn ON fn.oid = fc.relnamespace
            CROSS JOIN LATERAL unnest(k.conkey, k.confkey) WITH ORDINALITY AS u(col, fcol, ord)
            JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.col
            JOIN pg_attribute fa ON fa.attrelid = k.confrelid AND fa.attnum = u.fcol
            WHERE k.contype = 'f' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            ORDER BY n.nspname, c.relname, k.conname, u.ord
            """)
        return ForeignKey.grouping(result.rows)
    }

    nonisolated func selectAllSQL(from table: SchemaTable, limit: Int) -> String {
        "SELECT * FROM \(SQLiteClient.identifier(table.schema)).\(SQLiteClient.identifier(table.name)) LIMIT \(limit);"
    }

    func close() async {
        try? await connection.close()
    }

    /// The server reports a 1-based character position for syntax and name errors.
    static func position(of error: any Error, in sql: String) -> Int? {
        guard let error = error as? PSQLError, let text = error.serverInfo?[.position], let position = Int(text) else { return nil }
        return SQLText.utf16Offset(ofScalar: position - 1, in: sql)
    }

    /// PSQLError hides the server's message from its description; dig it out.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? PSQLError else {
            return (error as? DatabaseError)?.message ?? String(describing: error)
        }
        if let info = error.serverInfo, let message = info[.message] {
            var text = message
            if let detail = info[.detail] { text += "\nAyrıntı: \(detail)" }
            if let hint = info[.hint] { text += "\nİpucu: \(hint)" }
            return text
        }
        switch error.code {
        case .connectionError:
            return "Sunucuya bağlanılamadı" + (error.underlying.map { ": \($0)" } ?? ".")
        case .sslUnsupported:
            return "Sunucu TLS desteklemiyor. Bağlantı ayarlarında TLS'i kapatıp tekrar dene."
        case .authMechanismRequiresPassword:
            return "Sunucu parola istiyor."
        case .unsupportedAuthMechanism:
            return "Sunucunun kimlik doğrulama yöntemi desteklenmiyor."
        case .serverClosedConnection, .clientClosedConnection:
            return "Bağlantı kapandı."
        default:
            return String(reflecting: error)
        }
    }
}

/// Postgres sends results in binary; this turns the common types back into the text psql would show.
enum PostgresValueText {
    private static let postgresEpoch: TimeInterval = 946_684_800 // 2000-01-01 UTC

    static func text(_ bytes: ByteBuffer?, type: PostgresDataType, format: PostgresFormat) -> String? {
        guard var buffer = bytes else { return nil }
        if format == .text {
            return SQLText.shorten(buffer.readString(length: buffer.readableBytes) ?? "")
        }
        if let value = scalar(&buffer, type: type.rawValue) {
            return SQLText.shorten(value)
        }
        var copy = buffer
        if let array = array(&copy) {
            return SQLText.shorten(array)
        }
        let readable = buffer.readableBytes
        let bytes = buffer.readBytes(length: readable) ?? []
        // Enums, citext, xml and other text-like types are sent as plain UTF-8.
        if let text = String(bytes: bytes, encoding: .utf8), !text.contains("\0") {
            return SQLText.shorten(text)
        }
        return DatabaseValueText.blob(Data(bytes.prefix(64)), totalCount: readable)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func scalar(_ buffer: inout ByteBuffer, type: UInt32) -> String? {
        switch type {
        case 16: // bool
            return buffer.readInteger(as: UInt8.self).map { $0 != 0 ? "true" : "false" }
        case 21: return buffer.readInteger(as: Int16.self).map(String.init)
        case 23: return buffer.readInteger(as: Int32.self).map(String.init)
        case 20: return buffer.readInteger(as: Int64.self).map(String.init)
        case 26, 24, 28, 29, 2202...2206, 4089, 4096, 4191: // oid, xid, cid, reg* types
            return buffer.readInteger(as: UInt32.self).map(String.init)
        case 5069: return buffer.readInteger(as: UInt64.self).map(String.init) // xid8
        case 700:
            return buffer.readInteger(as: UInt32.self).map { number(Double(Float(bitPattern: $0))) }
        case 701:
            return buffer.readInteger(as: UInt64.self).map { number(Double(bitPattern: $0)) }
        case 1700:
            return PostgresData(type: .numeric, value: buffer).numeric?.string
        case 790: // money, in cents
            return buffer.readInteger(as: Int64.self).map { String(format: "%.2f", Double($0) / 100) }
        case 2950:
            guard let bytes = buffer.readBytes(length: 16) else { return nil }
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
        case 1082: // date: days since 2000-01-01
            guard let days = buffer.readInteger(as: Int32.self) else { return nil }
            if days == .max { return "infinity" }
            if days == .min { return "-infinity" }
            return dateFormatter.string(from: Date(timeIntervalSince1970: postgresEpoch + Double(days) * 86_400))
        case 1114, 1184: // timestamp, timestamptz: microseconds since 2000-01-01
            guard let micros = buffer.readInteger(as: Int64.self) else { return nil }
            if micros == .max { return "infinity" }
            if micros == .min { return "-infinity" }
            return timestamp(micros: micros, withTimeZone: type == 1184)
        case 1083: // time
            return buffer.readInteger(as: Int64.self).map(timeOfDay)
        case 1266: // timetz: time + offset in seconds west of UTC
            guard let micros = buffer.readInteger(as: Int64.self), let west = buffer.readInteger(as: Int32.self) else { return nil }
            return timeOfDay(micros) + offset(seconds: -Int(west))
        case 1186:
            guard let micros = buffer.readInteger(as: Int64.self), let days = buffer.readInteger(as: Int32.self),
                  let months = buffer.readInteger(as: Int32.self) else { return nil }
            return interval(micros: micros, days: days, months: months)
        case 3802: // jsonb: version byte, then text
            _ = buffer.readInteger(as: UInt8.self)
            return buffer.readString(length: buffer.readableBytes)
        case 17: // bytea
            let count = buffer.readableBytes
            return DatabaseValueText.blob(Data(buffer.readBytes(length: min(count, 64)) ?? []), totalCount: count)
        case 600: // point
            guard let x = buffer.readInteger(as: UInt64.self), let y = buffer.readInteger(as: UInt64.self) else { return nil }
            return "(\(number(Double(bitPattern: x))),\(number(Double(bitPattern: y))))"
        case 869, 650: // inet, cidr
            return inet(&buffer, isCIDR: type == 650)
        case 1560, 1562: // bit, varbit
            guard let length = buffer.readInteger(as: Int32.self), let bytes = buffer.readBytes(length: buffer.readableBytes) else { return nil }
            return String((0..<Int(length)).map { bytes[$0 / 8] & (0x80 >> UInt8($0 % 8)) != 0 ? "1" : "0" })
        case 3220: // pg_lsn
            return buffer.readInteger(as: UInt64.self).map { String(format: "%X/%X", $0 >> 32, $0 & 0xFFFF_FFFF) }
        default:
            return nil
        }
    }

    /// 2.0 → "2", like psql; other values as Swift prints them (shortest exact form).
    private static func number(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// The binary array format: dimensions, then length-prefixed elements of one type. Shown like psql: {1,2,"a b"}.
    private static func array(_ buffer: inout ByteBuffer) -> String? {
        guard let dimensions = buffer.readInteger(as: Int32.self), (0...6).contains(dimensions),
              let flags = buffer.readInteger(as: Int32.self), flags == 0 || flags == 1,
              let elementType = buffer.readInteger(as: UInt32.self), elementType != 0 else { return nil }
        if dimensions == 0 { return buffer.readableBytes == 0 ? "{}" : nil }
        var sizes: [Int] = []
        for _ in 0..<dimensions {
            guard let size = buffer.readInteger(as: Int32.self), size >= 0, buffer.readInteger(as: Int32.self) != nil else { return nil }
            sizes.append(Int(size))
        }
        let count = sizes.reduce(1, *)
        guard count <= 100_000 else { return nil }
        var elements: [String] = []
        for _ in 0..<count {
            guard let length = buffer.readInteger(as: Int32.self) else { return nil }
            if length == -1 {
                elements.append("NULL")
                continue
            }
            guard length >= 0, let slice = buffer.readSlice(length: Int(length)) else { return nil }
            let text = text(slice, type: PostgresDataType(elementType), format: .binary) ?? "NULL"
            elements.append(quoteArrayElement(text))
        }
        guard buffer.readableBytes == 0 else { return nil }
        return nest(elements[...], sizes: sizes[...])
    }

    private static func nest(_ elements: ArraySlice<String>, sizes: ArraySlice<Int>) -> String {
        guard sizes.count > 1, let first = sizes.first else { return "{" + elements.joined(separator: ",") + "}" }
        let chunk = elements.count / max(first, 1)
        let parts = stride(from: elements.startIndex, to: elements.endIndex, by: max(chunk, 1)).map { start in
            nest(elements[start..<min(start + chunk, elements.endIndex)], sizes: sizes.dropFirst())
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func quoteArrayElement(_ text: String) -> String {
        let needsQuotes = text.isEmpty || text.contains { " ,{}\"\\".contains($0) } || text.uppercased() == "NULL"
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// "2024-05-01 12:30:00.25", with "+03" for timestamptz (shown in the Mac's time zone, like psql).
    static func timestamp(micros: Int64, withTimeZone: Bool) -> String {
        var seconds = micros / 1_000_000
        var fraction = micros % 1_000_000
        if fraction < 0 {
            seconds -= 1
            fraction += 1_000_000
        }
        let date = Date(timeIntervalSince1970: postgresEpoch + Double(seconds))
        let zone = withTimeZone ? TimeZone.current : TimeZone(identifier: "UTC")!
        let formatter = withTimeZone ? localTimestampFormatter : timestampFormatter
        var text = formatter.string(from: date) + fractionText(fraction)
        if withTimeZone { text += offset(seconds: zone.secondsFromGMT(for: date)) }
        return text
    }

    private static func timeOfDay(_ micros: Int64) -> String {
        let seconds = micros / 1_000_000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) + fractionText(micros % 1_000_000)
    }

    /// ".25" for 250000 µs, "" for 0.
    private static func fractionText(_ micros: Int64) -> String {
        guard micros != 0 else { return "" }
        var digits = String(format: "%06lld", micros)
        while digits.hasSuffix("0") { digits.removeLast() }
        return "." + digits
    }

    private static func offset(seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) / 60 % 60
        return sign + String(format: "%02d", hours) + (minutes != 0 ? String(format: ":%02d", minutes) : "")
    }

    static func interval(micros: Int64, days: Int32, months: Int32) -> String {
        var parts: [String] = []
        let years = months / 12
        let remainingMonths = months % 12
        if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
        if remainingMonths != 0 { parts.append("\(remainingMonths) mon\(abs(remainingMonths) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty {
            parts.append((micros < 0 ? "-" : "") + timeOfDay(abs(micros)))
        }
        return parts.joined(separator: " ")
    }

    private static func inet(_ buffer: inout ByteBuffer, isCIDR: Bool) -> String? {
        guard let family = buffer.readInteger(as: UInt8.self), let bits = buffer.readInteger(as: UInt8.self),
              buffer.readInteger(as: UInt8.self) != nil, let length = buffer.readInteger(as: UInt8.self),
              let address = buffer.readBytes(length: Int(length)) else { return nil }
        let text: String
        if family == 2 || address.count == 4 { // AF_INET as Postgres numbers it
            text = address.map(String.init).joined(separator: ".")
        } else {
            var storage = in6_addr()
            withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: address.prefix(16)) }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &storage, &output, socklen_t(output.count)) != nil else { return nil }
            text = String(cString: output)
        }
        let maxBits = address.count * 8
        return isCIDR || Int(bits) != maxBits ? "\(text)/\(bits)" : text
    }

    private static func formatter(_ format: String, timeZone: TimeZone? = TimeZone(identifier: "UTC")) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static let dateFormatter = formatter("yyyy-MM-dd")
    private static let timestampFormatter = formatter("yyyy-MM-dd HH:mm:ss")
    private static let localTimestampFormatter = formatter("yyyy-MM-dd HH:mm:ss", timeZone: .current)
}
