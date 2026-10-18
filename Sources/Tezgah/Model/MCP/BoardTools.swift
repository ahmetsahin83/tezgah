import Foundation

/// Board tools: Claude reads the project's to-do board and keeps it up to date as it works.
extension WorkspaceStore {
    func registerBoardTools() {
        func object(_ properties: [String: [String: any Sendable]], required: [String] = []) -> [String: any Sendable] {
            ["type": "object", "properties": properties, "required": required]
        }
        let columns = ["todo", "doing", "done"]

        boardTool("board_list", "The project's to-do board in Tezgah, kept by the user: cards in todo, doing and done, each with an id. Check it when asked what to work on next.",
                  object(["include_done": ["type": "boolean", "description": "Also list finished cards (default false)"]])) { board, arguments in
            let includeDone = arguments["include_done"] as? Bool ?? false
            var lines: [String] = []
            for column in BoardCard.Column.allCases where includeDone || column != .done {
                let cards = board.cards(in: column)
                lines.append("## \(column.rawValue) (\(cards.count))")
                for card in cards {
                    lines.append("- [\(card.id.uuidString.prefix(8))] \(card.title)")
                    if !card.notes.isEmpty {
                        lines.append(contentsOf: card.notes.split(separator: "\n").prefix(6).map { "    \($0)" })
                    }
                }
            }
            return .text(board.cards.isEmpty ? "The board is empty." : lines.joined(separator: "\n"))
        }

        boardTool("board_add", "Add a card to the board, e.g. a follow-up you noticed. Goes to todo unless a column is given.",
                  object(["title": ["type": "string"], "notes": ["type": "string"], "column": ["type": "string", "enum": columns]], required: ["title"])) { board, arguments in
            let column = (arguments["column"] as? String).flatMap(BoardCard.Column.init(rawValue:)) ?? .todo
            guard let card = board.add(arguments["title"] as? String ?? "", notes: arguments["notes"] as? String ?? "", to: column) else {
                return .error("title is required")
            }
            return .text("Added [\(card.id.uuidString.prefix(8))] to \(column.rawValue).")
        }

        boardTool("board_move", "Move a card: to doing when you start on it, to done when it is finished.",
                  object(["id": ["type": "string", "description": "The id from board_list (the first 8 characters are enough)"],
                          "column": ["type": "string", "enum": columns]], required: ["id", "column"])) { board, arguments in
            guard let card = Self.card(board, arguments["id"]) else { return .error("No card with that id. Call board_list.") }
            guard let column = (arguments["column"] as? String).flatMap(BoardCard.Column.init(rawValue:)) else { return .error("column must be todo, doing or done") }
            board.move(card.id, to: column)
            return .text("Moved “\(card.title)” to \(column.rawValue).")
        }

        boardTool("board_update", "Change a card's title or notes, e.g. to note what was done or what is left.",
                  object(["id": ["type": "string"], "title": ["type": "string"], "notes": ["type": "string"]], required: ["id"])) { board, arguments in
            guard var card = Self.card(board, arguments["id"]) else { return .error("No card with that id. Call board_list.") }
            if let title = arguments["title"] as? String { card.title = title }
            if let notes = arguments["notes"] as? String { card.notes = notes }
            board.update(card)
            return .text("Updated “\(card.title)”.")
        }
    }

    private func boardTool(
        _ name: String, _ description: String, _ schema: [String: any Sendable],
        run: @escaping @MainActor (ProjectBoard, [String: Any]) async -> MCPToolResult
    ) {
        mcpServer.register(MCPTool(name: name, description: description, inputSchema: schema) { [weak self] arguments, tab in
            guard let self, let (_, project) = self.claudeTab(tab) else { return .error("This Claude session is not in Tezgah anymore.") }
            return await run(project.board, arguments)
        })
    }

    private static func card(_ board: ProjectBoard, _ id: Any?) -> BoardCard? {
        guard let text = (id as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).uppercased(), text.count >= 4 else { return nil }
        let matches = board.cards.filter { $0.id.uuidString.hasPrefix(text) }
        return matches.count == 1 ? matches[0] : nil
    }
}
