import Foundation
import Security

enum KeychainTokenStore {
    enum Error: Swift.Error {
        case notFound
        case status(OSStatus)
        case decode
    }

    private static let service = "Claude Code-credentials"

    static func readAccessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw Error.notFound
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Error.status(status)
        }
        guard let str = String(data: data, encoding: .utf8) else {
            throw Error.decode
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
                let candidates = ["accessToken", "access_token", "token"]
                for k in candidates {
                    if let v = obj[k] as? String, !v.isEmpty {
                        return v
                    }
                    if let claude = obj["claudeAiOauth"] as? [String: Any] {
                        if let v = claude[k] as? String, !v.isEmpty { return v }
                    }
                }
            }
            throw Error.decode
        }
        return trimmed
    }
}
