import Foundation
import Security

enum KeychainTokenStore {
    enum Error: Swift.Error {
        case notFound
        case status(OSStatus)
        case decode
    }

    private static let service = Strings.Keychain.claudeCodeService
    private static let accessQueue = DispatchQueue(label: "claude-usage-toolbar.keychain-access")
    private static var cachedAccessToken: String?

    static func requestAccess() async throws {
        try await withCheckedThrowingContinuation { continuation in
            NSLog("[ClaudeUsageToolbar] Keychain: requestAccess starting")
            accessQueue.async {
                do {
                    cachedAccessToken = try readAccessTokenWithoutQueue()
                    NSLog("[ClaudeUsageToolbar] Keychain: requestAccess succeeded (token length: %d)", cachedAccessToken?.count ?? 0)
                    continuation.resume()
                } catch {
                    NSLog("[ClaudeUsageToolbar] Keychain: requestAccess failed: %@", "\(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func readAccessToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            accessQueue.async {
                do {
                    continuation.resume(returning: try readAccessTokenWithoutQueue())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func invalidateCachedAccessToken() {
        accessQueue.async {
            NSLog("[ClaudeUsageToolbar] Keychain: invalidating cached token (was %@)", cachedAccessToken != nil ? "set" : "already nil")
            cachedAccessToken = nil
        }
    }

    private static func readAccessTokenWithoutQueue() throws -> String {
        if let cachedAccessToken {
            NSLog("[ClaudeUsageToolbar] Keychain: returning in-memory cached token (length: %d)", cachedAccessToken.count)
            return cachedAccessToken
        }
        NSLog("[ClaudeUsageToolbar] Keychain: cache miss — reading from keychain")
        let token = try readAccessTokenFromKeychain()
        cachedAccessToken = token
        return token
    }

    private static func readAccessTokenFromKeychain() throws -> String {
        NSLog("[ClaudeUsageToolbar] Keychain: querying service '%@'", service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            NSLog("[ClaudeUsageToolbar] Keychain: item not found for service '%@'", service)
            throw Error.notFound
        }
        guard status == errSecSuccess, let data = item as? Data else {
            NSLog("[ClaudeUsageToolbar] Keychain: query failed, OSStatus=%d", status)
            throw Error.status(status)
        }
        guard let str = String(data: data, encoding: .utf8) else {
            NSLog("[ClaudeUsageToolbar] Keychain: data is not valid UTF-8")
            throw Error.decode
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[ClaudeUsageToolbar] Keychain: raw data length=%d, isJSON=%@", trimmed.count, trimmed.hasPrefix("{") ? "yes" : "no")
        if trimmed.hasPrefix("{") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
                NSLog("[ClaudeUsageToolbar] Keychain: JSON keys: %@", obj.keys.sorted().joined(separator: ", "))
                let candidates = ["accessToken", "access_token", "token"]
                for k in candidates {
                    if let v = obj[k] as? String, !v.isEmpty {
                        NSLog("[ClaudeUsageToolbar] Keychain: found token at root key '%@' (length: %d)", k, v.count)
                        return v
                    }
                    if let claude = obj["claudeAiOauth"] as? [String: Any] {
                        NSLog("[ClaudeUsageToolbar] Keychain: claudeAiOauth keys: %@", claude.keys.sorted().joined(separator: ", "))
                        if let v = claude[k] as? String, !v.isEmpty {
                            NSLog("[ClaudeUsageToolbar] Keychain: found token at claudeAiOauth.%@ (length: %d)", k, v.count)
                            return v
                        }
                    }
                }
                NSLog("[ClaudeUsageToolbar] Keychain: JSON parsed but no token found in expected keys")
            } else {
                NSLog("[ClaudeUsageToolbar] Keychain: data starts with '{' but JSON parse failed")
            }
            throw Error.decode
        }
        NSLog("[ClaudeUsageToolbar] Keychain: plain-text token (length: %d)", trimmed.count)
        return trimmed
    }
}
