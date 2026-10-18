import Foundation
import Observation

/// One statement someone ran from the SQL editor.
struct QueryHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var sql: String
    var date: Date
    var duration: TimeInterval
    /// Rows returned, or rows affected.
    var rowCount: Int?
    var error: String?
    /// Who ran it when an agent did, e.g. "Geliştirici · Claude · Fable — Kart"; nil for the user.
    var agent: String?
}

/// Statements run on one connection, newest first, kept in Application Support/Tezgah/QueryHistory.
@MainActor
@Observable
final class QueryHistory {
    static let limit = 500

    private(set) var entries: [QueryHistoryEntry] = []
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var isLoaded = false
    /// Saves run one after another, so an older list can never overwrite a newer one.
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "dev.tezgah.query-history", qos: .utility)

    /// Without a directory (tests, previews) the history only lives in memory.
    init(directory: URL?, connectionID: UUID) {
        url = directory?.appendingPathComponent("\(connectionID.uuidString).json")
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([QueryHistoryEntry].self, from: data)) ?? []
    }

    func add(_ entry: QueryHistoryEntry) {
        loadIfNeeded()
        // Running the same statement again moves it to the top instead of repeating it.
        entries.removeAll { $0.sql == entry.sql }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ entry: QueryHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func search(_ query: String) -> [QueryHistoryEntry] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in words.allSatisfy { entry.sql.localizedCaseInsensitiveContains($0) } }
    }

    private func save() {
        guard let url else { return }
        let entries = entries
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(entries).write(to: url, options: .atomic)
            } catch {
                NSLog("Tezgah: could not save query history: \(error)")
            }
        }
    }
}
