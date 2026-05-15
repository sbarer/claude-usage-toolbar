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
    private static var persistentCacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("ClaudeUsageToolbar", isDirectory: true)
            .appendingPathComponent("access-token.cache")
    }

    static func requestAccess(completion: @escaping (Result<Void, Swift.Error>) -> Void) {
        NSLog("[ClaudeUsageToolbar] Keychain: requestAccess starting")
        accessQueue.async {
            do {
                cachedAccessToken = try readAccessTokenWithoutQueue()
                NSLog("[ClaudeUsageToolbar] Keychain: requestAccess succeeded (token length: %d)", cachedAccessToken?.count ?? 0)
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                NSLog("[ClaudeUsageToolbar] Keychain: requestAccess failed: %@", "\(error)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    static func readAccessToken() throws -> String {
        try accessQueue.sync {
            try readAccessTokenWithoutQueue()
        }
    }

    static func invalidateCachedAccessToken() {
        accessQueue.async {
            NSLog("[ClaudeUsageToolbar] Keychain: invalidating cached token (was %@)", cachedAccessToken != nil ? "set" : "already nil")
            cachedAccessToken = nil
            try? FileManager.default.removeItem(at: persistentCacheURL)
        }
    }

    private static func readAccessTokenWithoutQueue() throws -> String {
        if let cachedAccessToken {
            NSLog("[ClaudeUsageToolbar] Keychain: returning in-memory cached token (length: %d)", cachedAccessToken.count)
            return cachedAccessToken
        }
        if let token = try? readAccessTokenFromPersistentCache() {
            NSLog("[ClaudeUsageToolbar] Keychain: returning persistent-cache token (length: %d)", token.count)
            cachedAccessToken = token
            return token
        }
        NSLog("[ClaudeUsageToolbar] Keychain: cache miss — reading from keychain")
        let token = try readAccessTokenFromKeychain()
        cachedAccessToken = token
        do {
            try writeAccessTokenToPersistentCache(token)
            NSLog("[ClaudeUsageToolbar] Keychain: wrote token to persistent cache")
        } catch {
            NSLog("[ClaudeUsageToolbar] Keychain: persistent cache write failed: %@", "\(error)")
        }
        return token
    }

    private static func readAccessTokenFromPersistentCache() throws -> String {
        let data = try Data(contentsOf: persistentCacheURL)
        guard let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw Error.decode
        }
        return token
    }

    private static func writeAccessTokenToPersistentCache(_ token: String) throws {
        let url = persistentCacheURL
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
                        NSLog("[ClaudeUsageToolbar] Keychain: claudeAiOauth keys: %@", (claude.keys.sorted().joined(separator: ", ")))
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
