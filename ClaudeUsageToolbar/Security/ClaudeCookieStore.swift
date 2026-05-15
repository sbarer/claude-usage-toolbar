import Foundation
import CommonCrypto
import Security

enum ClaudeCookieStore {

    struct Cookies {
        let sessionKey: String
        let orgId: String
        let cfClearance: String?

        var cookieString: String {
            var parts = ["sessionKey=\(sessionKey)", "lastActiveOrg=\(orgId)"]
            if let cf = cfClearance { parts.append("cf_clearance=\(cf)") }
            return parts.joined(separator: "; ")
        }
    }

    enum Error: Swift.Error {
        case cookieNotFound(String)
        case decryptionFailed
        case keychainNotFound
        case keychainError(OSStatus)
        case databaseQueryFailed(String)
    }

    private static let cookieDBPath = NSHomeDirectory() + "/Library/Application Support/Claude/Cookies"
    private static let keychainService = "Claude Safe Storage"
    private static let decryptedPrefixLength = 32
    private static var cachedKey: Data?

    static func readCookies() throws -> Cookies {
        let sessionKey = try readCookie(named: "sessionKey")
        let orgId = try readCookie(named: "lastActiveOrg")
        let cfClearance = try? readCookie(named: "cf_clearance")
        return Cookies(sessionKey: sessionKey, orgId: orgId, cfClearance: cfClearance)
    }

    private static func readCookie(named name: String) throws -> String {
        let hex = try queryCookieHex(name: name)
        return try decryptHex(hex)
    }

    private static func queryCookieHex(name: String) throws -> String {
        // Use sqlite3 CLI since app sandbox is disabled — same approach as the reference implementation.
        // WAL-mode SQLite allows concurrent readers alongside Claude Desktop holding the DB open.
        let sql = "SELECT hex(encrypted_value) FROM cookies WHERE host_key = '.claude.ai' AND name = '\(name)' LIMIT 1;"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", cookieDBPath, sql]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw Error.databaseQueryFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty { throw Error.cookieNotFound(name) }
        return output
    }

    private static func decryptHex(_ hex: String) throws -> String {
        guard let data = Data(hexEncoded: hex),
              data.count > 3,
              data.prefix(3) == Data([0x76, 0x31, 0x30]) else { // "v10"
            throw Error.decryptionFailed
        }

        let key = try encryptionKey()
        let iv = Data(repeating: 0x20, count: 16) // 16 ASCII space characters, as Chromium specifies
        let ciphertext = data.dropFirst(3)

        var decrypted = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength = 0

        let status: CCCryptorStatus = decrypted.withUnsafeMutableBytes { decBuf in
            ciphertext.withUnsafeBytes { cipherBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            cipherBuf.baseAddress, ciphertext.count,
                            decBuf.baseAddress, decBuf.count,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { throw Error.decryptionFailed }

        let plaintext = decrypted.prefix(decryptedLength)
        guard plaintext.count > decryptedPrefixLength,
              let result = String(data: plaintext.dropFirst(decryptedPrefixLength), encoding: .utf8) else {
            throw Error.decryptionFailed
        }
        return result
    }

    private static func encryptionKey() throws -> Data {
        if let key = cachedKey { return key }

        // Chromium-family apps store the AES key password under service "{App} Safe Storage"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? Error.keychainNotFound : Error.keychainError(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw Error.decryptionFailed
        }

        // PBKDF2-SHA1, 1003 iterations, 16-byte key — Chromium's fixed parameters
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: 16)
        let pbkdfStatus: CCCryptorStatus = derivedKey.withUnsafeMutableBytes { keyBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.utf8.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBuf.bindMemory(to: UInt8.self).baseAddress, 16
                )
            }
        }
        guard pbkdfStatus == kCCSuccess else { throw Error.decryptionFailed }

        cachedKey = derivedKey
        return derivedKey
    }
}

private extension Data {
    init?(hexEncoded: String) {
        let hex = hexEncoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
