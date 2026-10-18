import Foundation
import Network

/// A tool Tezgah offers to the Claude sessions it starts.
struct MCPTool: Sendable {
    let name: String
    let description: String
    /// JSON Schema of the arguments.
    let inputSchema: [String: any Sendable]
    let run: @MainActor @Sendable (_ arguments: [String: Any], _ tab: UUID) async -> MCPToolResult
}

struct MCPToolResult: Sendable {
    enum Content: Sendable {
        case text(String)
        /// PNG data.
        case image(Data)
    }

    var content: [Content]
    var isError = false

    static func text(_ text: String) -> MCPToolResult { MCPToolResult(content: [.text(text)]) }
    static func error(_ text: String) -> MCPToolResult { MCPToolResult(content: [.text(text)], isError: true) }
}

/// A Model Context Protocol server on 127.0.0.1, spoken over plain HTTP (the "streamable HTTP"
/// transport, answering every request with a single JSON response).
///
/// Claude sessions started by Tezgah get it through `--mcp-config`; the path carries the tab's id
/// (`/mcp/<tab>`), so a tool knows which session, project and preview it works for. Requests need
/// the token Tezgah made at launch, so other programs on the machine can't use the tools.
final class MCPServer: @unchecked Sendable {
    let token = UUID().uuidString
    private let queue = DispatchQueue(label: "dev.tezgah.mcp")
    private var listener: NWListener?
    private var tools: [String: MCPTool] = [:]
    private var toolOrder: [String] = []
    private var portWaiters: [CheckedContinuation<UInt16?, Never>] = []
    private var port: UInt16?
    private var failed = false

    func register(_ tool: MCPTool) {
        queue.sync {
            if tools[tool.name] == nil { toolOrder.append(tool.name) }
            tools[tool.name] = tool
        }
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            finishWaiting(with: nil)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.finishWaiting(with: listener.port?.rawValue)
            case .failed, .cancelled:
                self.finishWaiting(with: nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The port, once listening; nil if the server could not start.
    func readyPort() async -> UInt16? {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.port != nil || self.failed {
                    continuation.resume(returning: self.port)
                } else {
                    self.portWaiters.append(continuation)
                }
            }
        }
    }

    /// Where a tab's session reaches the tools.
    func url(forTab tab: UUID, port: UInt16) -> String {
        "http://127.0.0.1:\(port)/mcp/\(tab.uuidString)"
    }

    /// `--mcp-config` for a Claude tab's session.
    func config(forTab tab: UUID, port: UInt16) -> String {
        let config: [String: Any] = [
            "mcpServers": [
                "tezgah": [
                    "type": "http",
                    "url": url(forTab: tab, port: port),
                    "headers": ["Authorization": "Bearer \(token)"],
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func finishWaiting(with port: UInt16?) {
        queue.async {
            if let port { self.port = port } else { self.failed = true }
            let waiters = self.portWaiters
            self.portWaiters = []
            waiters.forEach { $0.resume(returning: self.port) }
        }
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads one request (headers, then Content-Length bytes), answers it, then waits for the
    /// next one on the same connection, which Claude Code keeps alive.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        if let request = HTTPRequest.parse(buffer) {
            let rest = buffer.dropFirst(request.length)
            handle(request) { [weak self] response in
                connection.send(content: response, completion: .contentProcessed { error in
                    guard let self, error == nil else {
                        connection.cancel()
                        return
                    }
                    self.queue.async { self.receiveRequest(on: connection, buffer: Data(rest)) }
                })
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveRequest(on: connection, buffer: buffer + data)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, respond: @escaping @Sendable (Data) -> Void) {
        guard request.headers["authorization"] == "Bearer \(token)" else {
            respond(HTTPRequest.response(status: "401 Unauthorized"))
            return
        }
        let parts = request.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "mcp", let tab = UUID(uuidString: String(parts[1])) else {
            respond(HTTPRequest.response(status: "404 Not Found"))
            return
        }
        switch request.method {
        case "POST":
            break
        case "DELETE":
            respond(HTTPRequest.response(status: "200 OK"))
            return
        default:
            // No server-initiated stream: every answer comes with its request.
            respond(HTTPRequest.response(status: "405 Method Not Allowed", headers: ["Allow": "POST, DELETE"]))
            return
        }
        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let method = message["method"] as? String else {
            respond(HTTPRequest.response(status: "400 Bad Request"))
            return
        }
        guard let id = message["id"] else {
            // A notification: nothing to answer.
            respond(HTTPRequest.response(status: "202 Accepted"))
            return
        }

        switch method {
        case "initialize":
            let params = message["params"] as? [String: Any]
            respond(rpc(id: id, result: [
                "protocolVersion": params?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "tezgah", "title": "Tezgah", "version": "1.0"],
                "instructions": Self.instructions,
            ]))
        case "ping":
            respond(rpc(id: id, result: [:]))
        case "tools/list":
            let list = toolOrder.compactMap { tools[$0] }.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema]
            }
            respond(rpc(id: id, result: ["tools": list]))
        case "tools/call":
            let params = message["params"] as? [String: Any]
            guard let name = params?["name"] as? String, let tool = tools[name] else {
                respond(rpc(id: id, error: (-32602, "Unknown tool")))
                return
            }
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            nonisolated(unsafe) let unsafeArguments = arguments
            nonisolated(unsafe) let unsafeID = id
            Task { @MainActor in
                let result = await tool.run(unsafeArguments, tab)
                let response = self.rpc(id: unsafeID, result: Self.encode(result))
                respond(response)
            }
        default:
            respond(rpc(id: id, error: (-32601, "Method not found: \(method)")))
        }
    }

    private static let instructions = """
    Tezgah is the macOS workspace this session runs in. Its tools show things to the user inside \
    Tezgah: open a file at a line, preview web pages in a browser tab you can drive, and run apps \
    on the iOS Simulator in a device tab. Prefer them over asking the user to look at something. \
    The project also has a to-do board (board_* tools): when you take on a card, move it to doing, \
    and to done when it is finished. To split work across agents, start them with agent_spawn (each \
    gets its own git worktree and branch and shows up as a tab), wait for them with agent_wait, give \
    feedback with agent_send and merge finished branches with agent_merge.
    """

    private static func encode(_ result: MCPToolResult) -> [String: Any] {
        let content = result.content.map { item -> [String: Any] in
            switch item {
            case .text(let text): ["type": "text", "text": text]
            case .image(let png): ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]
            }
        }
        return ["content": content, "isError": result.isError]
    }

    private func rpc(id: Any, result: [String: Any]) -> Data {
        body(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func rpc(id: Any, error: (code: Int, message: String)) -> Data {
        body(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }

    private func body(_ object: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPRequest.response(status: "200 OK", headers: ["Content-Type": "application/json"], body: json)
    }
}

/// Just enough HTTP/1.1 for MCP over localhost.
struct HTTPRequest {
    let method: String
    let path: String
    /// Lowercased names.
    let headers: [String: String]
    let body: Data
    /// Bytes this request took up in the buffer.
    let length: Int

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= bodyLength else { return nil }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: bodyLength)]
        // Query strings are not used; keep the path only.
        let path = String(requestLine[1].split(separator: "?").first ?? "")
        return HTTPRequest(
            method: String(requestLine[0]), path: path, headers: headers, body: Data(body),
            length: data.distance(from: data.startIndex, to: bodyStart) + bodyLength
        )
    }

    static func response(status: String, headers: [String: String] = [:], body: Data = Data()) -> Data {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
