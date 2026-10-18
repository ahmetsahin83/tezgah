import Foundation

/// Keyword and function names for completion and formatting.
enum SQLKeywords {
    /// Words that cannot be a bare identifier (or an alias right after a table name).
    static let reserved: Set<String> = [
        "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BETWEEN", "BY", "CASE", "CHECK", "COLUMN", "CONSTRAINT",
        "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DEFAULT", "DELETE", "DESC",
        "DISTINCT", "DROP", "ELSE", "END", "EXCEPT", "EXISTS", "FALSE", "FETCH", "FOR", "FOREIGN", "FROM", "FULL",
        "GRANT", "GROUP", "HAVING", "IN", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "LEFT", "LIKE",
        "LIMIT", "NATURAL", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES",
        "RETURNING", "RIGHT", "SELECT", "SET", "TABLE", "THEN", "TO", "TRUE", "UNION", "UNIQUE", "UPDATE",
        "USING", "VALUES", "WHEN", "WHERE", "WINDOW", "WITH", "ILIKE", "LATERAL", "OVER", "PARTITION",
    ]

    /// Words after which a table name follows.
    static let tableIntroducers: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "TRUNCATE", "DESCRIBE"]

    /// Words after which an expression (usually a column) follows.
    static let expressionIntroducers: Set<String> = [
        "SELECT", "WHERE", "ON", "AND", "OR", "HAVING", "BY", "SET", "RETURNING", "WHEN", "THEN", "ELSE",
        "NOT", "DISTINCT", "CASE", "IS", "LIKE", "ILIKE", "IN", "BETWEEN", "USING", "VALUES", "OVER",
    ]

    /// Clause words that start a new part of a statement, for the formatter and for clause detection.
    static let clauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT",
        "EXCEPT", "INSERT", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "WITH", "JOIN", "ON", "INTO",
        "WINDOW", "FETCH",
    ]

    /// Keywords offered by completion, roughly by how often they are typed.
    static func keywords(for dialect: DatabaseConfig.Kind) -> [String] {
        var words = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "NULL", "IS NULL", "IS NOT NULL", "IN", "LIKE",
            "BETWEEN", "EXISTS", "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "ON",
            "AS", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC", "DISTINCT", "UNION",
            "UNION ALL", "INTERSECT", "EXCEPT", "CASE", "WHEN", "THEN", "ELSE", "END", "INSERT INTO", "VALUES",
            "UPDATE", "SET", "DELETE FROM", "WITH", "CREATE TABLE", "CREATE INDEX", "CREATE VIEW", "ALTER TABLE",
            "DROP TABLE", "DROP INDEX", "ADD COLUMN", "DROP COLUMN", "PRIMARY KEY", "FOREIGN KEY", "REFERENCES",
            "UNIQUE", "DEFAULT", "CHECK", "CONSTRAINT", "TRUE", "FALSE", "BEGIN", "COMMIT", "ROLLBACK",
            "EXPLAIN", "OVER", "PARTITION BY", "USING", "ALL", "ANY", "IF EXISTS", "IF NOT EXISTS",
        ]
        switch dialect {
        case .postgres:
            words += [
                "ILIKE", "RETURNING", "ON CONFLICT", "DO NOTHING", "DO UPDATE SET", "LATERAL", "FILTER",
                "NULLS FIRST", "NULLS LAST", "EXPLAIN ANALYZE", "TRUNCATE", "SHOW", "SERIAL", "BIGSERIAL",
                "TEXT", "INTEGER", "BIGINT", "BOOLEAN", "TIMESTAMPTZ", "TIMESTAMP", "JSONB", "UUID", "NUMERIC",
                "VARCHAR", "MATERIALIZED VIEW", "REFRESH MATERIALIZED VIEW", "VACUUM", "ANALYZE", "SCHEMA",
            ]
        case .mysql:
            words += [
                "SHOW TABLES", "SHOW DATABASES", "SHOW CREATE TABLE", "DESCRIBE", "USE", "AUTO_INCREMENT",
                "ON DUPLICATE KEY UPDATE", "REPLACE INTO", "INSERT IGNORE", "STRAIGHT_JOIN", "ENGINE", "TRUNCATE",
                "INT", "BIGINT", "VARCHAR", "TEXT", "DATETIME", "TIMESTAMP", "DECIMAL", "TINYINT", "JSON", "ENUM",
                "START TRANSACTION", "LOCK TABLES", "UNLOCK TABLES",
            ]
        case .sqlite:
            words += [
                "PRAGMA", "AUTOINCREMENT", "INTEGER PRIMARY KEY", "WITHOUT ROWID", "ON CONFLICT", "REPLACE",
                "INSERT OR REPLACE", "INSERT OR IGNORE", "RETURNING", "GLOB", "VACUUM", "ATTACH DATABASE",
                "TEXT", "INTEGER", "REAL", "BLOB", "NUMERIC",
            ]
        }
        return words
    }

    static func functions(for dialect: DatabaseConfig.Kind) -> [String] {
        var names = [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "LOWER", "UPPER", "LENGTH", "TRIM",
            "SUBSTR", "REPLACE", "ROUND", "ABS", "CAST", "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD",
            "FIRST_VALUE", "LAST_VALUE",
        ]
        switch dialect {
        case .postgres:
            names += [
                "NOW", "STRING_AGG", "ARRAY_AGG", "JSON_AGG", "JSONB_AGG", "JSONB_BUILD_OBJECT", "JSON_BUILD_OBJECT",
                "JSONB_EXTRACT_PATH_TEXT", "TO_CHAR", "TO_DATE", "TO_TIMESTAMP", "DATE_TRUNC", "DATE_PART", "EXTRACT",
                "AGE", "GENERATE_SERIES", "UNNEST", "ARRAY_LENGTH", "SUBSTRING", "POSITION", "SPLIT_PART",
                "REGEXP_REPLACE", "REGEXP_MATCHES", "CONCAT", "CONCAT_WS", "GREATEST", "LEAST", "GEN_RANDOM_UUID",
                "CURRENT_SETTING", "PG_SIZE_PRETTY", "PG_TOTAL_RELATION_SIZE", "BOOL_AND", "BOOL_OR", "FLOOR", "CEIL",
                "RANDOM", "LEFT", "RIGHT", "LPAD", "RPAD", "MD5", "FORMAT",
            ]
        case .mysql:
            names += [
                "NOW", "CURDATE", "CURTIME", "DATE_FORMAT", "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF",
                "UNIX_TIMESTAMP", "FROM_UNIXTIME", "STR_TO_DATE", "IFNULL", "IF", "GROUP_CONCAT", "CONCAT",
                "CONCAT_WS", "SUBSTRING", "SUBSTRING_INDEX", "LOCATE", "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_OBJECT",
                "JSON_ARRAY", "JSON_ARRAYAGG", "JSON_OBJECTAGG", "GREATEST", "LEAST", "FLOOR", "CEIL", "RAND", "UUID",
                "LAST_INSERT_ID", "FOUND_ROWS", "DATE", "YEAR", "MONTH", "DAY", "LEFT", "RIGHT", "LPAD", "RPAD", "MD5",
            ]
        case .sqlite:
            names += [
                "IFNULL", "IIF", "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME", "UNIXEPOCH", "GROUP_CONCAT",
                "JSON_EXTRACT", "JSON_OBJECT", "JSON_ARRAY", "JSON_GROUP_ARRAY", "JSON_GROUP_OBJECT", "INSTR",
                "PRINTF", "FORMAT", "TYPEOF", "RANDOM", "LAST_INSERT_ROWID", "CHANGES", "HEX", "QUOTE", "LIKE", "GLOB",
            ]
        }
        return names
    }
}
