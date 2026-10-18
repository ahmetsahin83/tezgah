import Foundation
import Testing
@testable import Tezgah

@MainActor
@Suite struct MCPServerTests {
    private func post(_ port: UInt16, tab: UUID, token: String, _ body: [String: Any]) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp/\(tab.uuidString)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
    }

    @Test func speaksMCPOverHTTP() async throws {
        let server = MCPServer()
        let calledFrom = Box()
        server.register(MCPTool(name: "echo", description: "Echo", inputSchema: ["type": "object"]) { arguments, tab in
            calledFrom.value = tab
            return .text("echo: \(arguments["text"] as? String ?? "")")
        })
        server.start()
        defer { server.stop() }
        let port = try #require(await server.readyPort())
        let tab = UUID()

        let (denied, _) = try await post(port, tab: tab, token: "wrong", ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        #expect(denied == 401)

        let (_, initialized) = try await post(port, tab: tab, token: server.token, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"],
        ])
        let result = try #require(initialized?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")

        let (accepted, _) = try await post(port, tab: tab, token: server.token, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(accepted == 202)

        let (_, list) = try await post(port, tab: tab, token: server.token, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try #require((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["echo"])

        let (_, call) = try await post(port, tab: tab, token: server.token, [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"]],
        ])
        let content = try #require((call?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "echo: hi")
        #expect(await calledFrom.value == tab)

        let (_, unknown) = try await post(port, tab: tab, token: server.token, ["jsonrpc": "2.0", "id": 4, "method": "server/discover"])
        #expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32601)
    }
}

@MainActor
private final class Box {
    var value: UUID?
}
