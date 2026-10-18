import Foundation
import Observation

/// The project's "Search" tab: a query, its options and the matches.
@MainActor
@Observable
final class SearchModel: Identifiable {
    let id = UUID()
    let rootURL: URL
    var options = TextSearch.Options() {
        didSet { if options != oldValue { scheduleSearch() } }
    }
    private(set) var output = TextSearch.Output()
    private(set) var isSearching = false
    private(set) var error: String?
    /// The query the results belong to.
    private(set) var searchedQuery = ""
    /// Files whose matches are folded away.
    var collapsedPaths: Set<String> = []
    /// Bumped to move keyboard focus to the query field.
    private(set) var focusRequest = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func focus(query: String? = nil) {
        if let query, !query.isEmpty { options.query = query }
        focusRequest += 1
    }

    /// Searches shortly after typing stops. Single characters wait for return, they match too much.
    private func scheduleSearch() {
        task?.cancel()
        guard options.query.count >= 2 else {
            if options.query.isEmpty { clear() }
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    func searchNow() {
        task?.cancel()
        guard !options.query.isEmpty else { return clear() }
        task = Task { [weak self] in await self?.performSearch() }
    }

    private func clear() {
        output = TextSearch.Output()
        searchedQuery = ""
        error = nil
        isSearching = false
    }

    private func performSearch() async {
        let options = options
        isSearching = true
        do {
            let found = try await TextSearch.run(options, in: rootURL)
            guard !Task.isCancelled else { return }
            output = found
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            output = TextSearch.Output()
            self.error = error.localizedDescription
        }
        searchedQuery = options.query
        collapsedPaths = []
        isSearching = false
    }
}
