import Foundation
import Security

enum KeychainTokenStore {
    enum Error: Swift.Error {
        case notFound
        case status(OSStatus)
        case decode
    }

    private static let service = "Claude Code-credentials"
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
        accessQueue.async {
            do {
                cachedAccessToken = try readAccessTokenWithoutQueue()
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
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
            cachedAccessToken = nil
            try? FileManager.default.removeItem(at: persistentCacheURL)
        }
    }

    private static func readAccessTokenWithoutQueue() throws -> String {
        if let cachedAccessToken {
            return cachedAccessToken
        }
        if let token = try? readAccessTokenFromPersistentCache() {
            cachedAccessToken = token
            return token
        }
        let token = try readAccessTokenFromKeychain()
        cachedAccessToken = token
        try? writeAccessTokenToPersistentCache(token)
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
