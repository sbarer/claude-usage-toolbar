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
            NSLog("Keychain: requestAccess starting")
            accessQueue.async {
                do {
                    cachedAccessToken = try readAccessTokenWithoutQueue()
                    NSLog("Keychain: requestAccess succeeded (token length: %d)", cachedAccessToken?.count ?? 0)
                    continuation.resume()
                } catch {
                    NSLog("Keychain: requestAccess failed: %@", "\(error)")
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
            NSLog("Keychain: invalidating cached token (was %@)", cachedAccessToken != nil ? "set" : "already nil")
            cachedAccessToken = nil
        }
    }

    private static func readAccessTokenWithoutQueue() throws -> String {
        if let cachedAccessToken {
            NSLog("Keychain: returning in-memory cached token (length: %d)", cachedAccessToken.count)
            return cachedAccessToken
        }
        NSLog("Keychain: cache miss — reading from keychain")
        let token = try readAccessTokenFromKeychain()
        cachedAccessToken = token
        return token
    }

    private static func readAccessTokenFromKeychain() throws -> String {
        NSLog("Keychain: querying service '%@'", service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            NSLog("Keychain: item not found for service '%@'", service)
            throw Error.notFound
        }
        guard status == errSecSuccess, let data = item as? Data else {
            NSLog("Keychain: query failed, OSStatus=%d", status)
            throw Error.status(status)
        }
        guard let str = String(data: data, encoding: .utf8) else {
            NSLog("Keychain: data is not valid UTF-8")
            throw Error.decode
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("Keychain: raw data length=%d, isJSON=%@", trimmed.count, trimmed.hasPrefix("{") ? "yes" : "no")
        if trimmed.hasPrefix("{") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
                NSLog("Keychain: JSON keys: %@", obj.keys.sorted().joined(separator: ", "))
                let candidates = ["accessToken", "access_token", "token"]
                for k in candidates {
                    if let v = obj[k] as? String, !v.isEmpty {
                        NSLog("Keychain: found token at root key '%@' (length: %d)", k, v.count)
                        return v
                    }
                    if let claude = obj["claudeAiOauth"] as? [String: Any] {
                        NSLog("Keychain: claudeAiOauth keys: %@", claude.keys.sorted().joined(separator: ", "))
                        if let v = claude[k] as? String, !v.isEmpty {
                            NSLog("Keychain: found token at claudeAiOauth.%@ (length: %d)", k, v.count)
                            return v
                        }
                    }
                }
                NSLog("Keychain: JSON parsed but no token found in expected keys")
            } else {
                NSLog("Keychain: data starts with '{' but JSON parse failed")
            }
            throw Error.decode
        }
        NSLog("Keychain: plain-text token (length: %d)", trimmed.count)
        return trimmed
    }
}
