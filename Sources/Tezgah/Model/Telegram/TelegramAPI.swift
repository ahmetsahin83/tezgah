import Foundation

/// A Bot API call: the method and its parameters in, the `result` out.
protocol TelegramTransport: Sendable {
    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any
}

struct TelegramError: LocalizedError {
    /// Telegram's error code: 401 a wrong token, 409 another program reading the same bot.
    let code: Int
    let description: String

    var errorDescription: String? { description }
}

/// Telegram's Bot API over HTTPS. Tezgah only ever calls out, so no server and no open port.
struct TelegramHTTP: TelegramTransport {
    let token: String

    func call(_ method: String, _ parameters: [String: Any]) async throws -> Any {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramError(code: 0, description: "Geçersiz bot token'ı")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        // A long poll waits up to its own timeout before Telegram answers.
        request.timeoutInterval = Double((parameters["timeout"] as? Int) ?? 0) + 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard json?["ok"] as? Bool == true else {
            throw TelegramError(
                code: json?["error_code"] as? Int ?? (response as? HTTPURLResponse)?.statusCode ?? 0,
                description: json?["description"] as? String ?? "Telegram'a ulaşılamadı"
            )
        }
        return json?["result"] ?? NSNull()
    }
}

/// The bot token, in the Keychain.
enum TelegramToken {
    private static let service = "dev.ahmetsahin.tezgah.telegram"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "bot",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String?) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "bot",
        ]
        SecItemDelete(item as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var added = item
        added[kSecValueData as String] = Data(token.utf8)
        added[kSecAttrLabel as String] = "Tezgah Telegram botu"
        SecItemAdd(added as CFDictionary, nil)
    }
}
