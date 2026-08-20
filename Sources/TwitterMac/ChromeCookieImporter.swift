import AppKit
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3
import WebKit

/// Imports x.com session cookies from the user's own Chrome profile so they never
/// type credentials into the webview. Reads Chrome's encrypted cookie database (SQLite),
/// decrypts values with the Keychain-stored Chrome Safe Storage key, and returns
/// ready-to-inject HTTPCookie objects.
///
/// Security: decrypted cookie values are never written to disk or logs. The temp DB
/// copy is deleted after reading. The API key stays in memory only.
final class ChromeCookieImporter {

    struct ImportResult {
        let profileName: String
        let cookieCount: Int
        let cookies: [HTTPCookie]
    }

    enum ImportError: Error, LocalizedError {
        case keychainDenied
        case keychainReadFailed(String)
        case noChromeProfiles
        case noXCookies
        case sqliteError(String)
        case decryptionFailed(String)
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .keychainDenied:
                return "Keychain access was denied. Click \"Sign in from Chrome\" again and approve the prompt to read Chrome's encryption key."
            case .keychainReadFailed(let msg):
                return "Could not read Chrome's Safe Storage key from Keychain: \(msg)"
            case .noChromeProfiles:
                return "No Chrome profile directories found. Is Chrome installed?"
            case .noXCookies:
                return "No x.com or twitter.com cookies found in any Chrome profile. Make sure you're logged into x.com in Chrome first."
            case .sqliteError(let msg):
                return "Could not read Chrome's cookie database: \(msg)"
            case .decryptionFailed(let msg):
                return "Could not decrypt Chrome cookies: \(msg)"
            case .userCancelled:
                return "Import cancelled."
            }
        }
    }

    /// Cookie names needed for a logged-in x.com session.
    private static let cookieNames: Set<String> = [
        "auth_token", "ct0", "twid", "kdt", "att"
    ]

    private static let chromeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")

    // MARK: - Public

    func importCookies() throws -> ImportResult {
        // 1. Read Chrome Safe Storage password from Keychain (may show a prompt).
        let password = try readKeychainPassword()

        // 2. Derive the AES-128 key.
        let key = try deriveKey(password: password)

        // 3. Enumerate Chrome profiles.
        let profiles = enumerateProfiles()
        guard !profiles.isEmpty else { throw ImportError.noChromeProfiles }

        // 4. Read cookies from each profile, filter for x.com/twitter.com.
        var candidates: [(name: String, cookies: [RawCookie])] = []
        for profile in profiles {
            let cookies = try readCookies(from: profile)
            let xCookies = cookies.filter { c in
                isXDomain(c.hostKey) && Self.cookieNames.contains(c.name)
            }
            if !xCookies.isEmpty {
                candidates.append((name: profile.name, cookies: xCookies))
            }
        }
        guard !candidates.isEmpty else { throw ImportError.noXCookies }

        // 5. Pick a profile (auto if one, user picks if multiple).
        let selected: (name: String, cookies: [RawCookie])
        if candidates.count == 1 {
            selected = candidates[0]
        } else {
            guard let pick = pickProfile(candidates) else { throw ImportError.userCancelled }
            selected = pick
        }

        // 6. Decrypt and build HTTPCookie objects.
        var httpCookies: [HTTPCookie] = []
        for raw in selected.cookies {
            let value = decryptValue(raw, key: key)
            guard !value.isEmpty else { continue }
            if let cookie = buildHTTPCookie(from: raw, value: value) {
                httpCookies.append(cookie)
            }
        }
        guard !httpCookies.isEmpty else {
            throw ImportError.decryptionFailed("no cookies decrypted successfully")
        }

        return ImportResult(
            profileName: selected.name,
            cookieCount: httpCookies.count,
            cookies: httpCookies
        )
    }

    // MARK: - Keychain

    private func readKeychainPassword() throws -> String {
        let context = LAContext()
        context.localizedReason = "TwitterMac wants to use your Chrome Safe Storage key to import your x.com cookies."
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let password = String(data: data, encoding: .utf8)
            else { throw ImportError.keychainReadFailed("unexpected data format") }
            return password
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw ImportError.keychainDenied
        default:
            throw ImportError.keychainReadFailed("OSStatus \(status)")
        }
    }

    // MARK: - Key derivation (PBKDF2-HMAC-SHA1)

    private func deriveKey(password: String) throws -> [UInt8] {
        let salt = Array("saltysalt".utf8)
        var derivedKey = [UInt8](repeating: 0, count: 16)

        let status = salt.withUnsafeBufferPointer { saltPtr -> Int32 in
            derivedKey.withUnsafeMutableBufferPointer { keyPtr -> Int32 in
                password.withCString { passwordPtr -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr, password.utf8.count,
                        saltPtr.baseAddress!, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyPtr.baseAddress!, 16
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw ImportError.decryptionFailed("PBKDF2 key derivation failed (\(status))")
        }
        return derivedKey
    }

    // MARK: - Profile enumeration

    private struct Profile {
        let name: String
        let dir: URL
    }

    private func enumerateProfiles() -> [Profile] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Self.chromeDir.path)
        else { return [] }

        return entries.compactMap { name in
            let dir = Self.chromeDir.appendingPathComponent(name)
            let cookies = dir.appendingPathComponent("Cookies")
            guard fm.fileExists(atPath: cookies.path) else { return nil }
            return Profile(name: name, dir: dir)
        }
    }

    // MARK: - SQLite

    private struct RawCookie {
        let hostKey: String
        let name: String
        let value: String
        let path: String
        let expiresUTC: Int64
        let isSecure: Bool
        let isHTTPOnly: Bool
        let encryptedValue: Data
    }

    private func readCookies(from profile: Profile) throws -> [RawCookie] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("tmac-chrome-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Copy the cookie DB and WAL/journal files — Chrome holds a lock on the original.
        for file in ["Cookies", "Cookies-wal", "Cookies-shm", "Cookies-journal"] {
            let src = profile.dir.appendingPathComponent(file)
            let dst = tempDir.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }

        let dbPath = tempDir.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw ImportError.sqliteError(msg)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT host_key, name, value, path, expires_utc, is_secure, is_httponly, encrypted_value
            FROM cookies
            WHERE host_key IN ('.x.com', 'x.com', '.twitter.com', 'twitter.com')
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ImportError.sqliteError(msg)
        }
        defer { sqlite3_finalize(stmt) }

        var cookies: [RawCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            cookies.append(RawCookie(
                hostKey: columnString(stmt, 0),
                name: columnString(stmt, 1),
                value: columnString(stmt, 2),
                path: columnString(stmt, 3),
                expiresUTC: sqlite3_column_int64(stmt, 4),
                isSecure: sqlite3_column_int(stmt, 5) != 0,
                isHTTPOnly: sqlite3_column_int(stmt, 6) != 0,
                encryptedValue: columnData(stmt, 7)
            ))
        }
        return cookies
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return cString.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
            String(cString: ptr)
        }
    }

    private func columnData(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        let size = Int(sqlite3_column_bytes(stmt, index))
        guard size > 0, let blob = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: blob, count: size)
    }

    // MARK: - Decryption (AES-128-CBC)

    private func decryptValue(_ raw: RawCookie, key: [UInt8]) -> String {
        if raw.encryptedValue.isEmpty {
            return raw.value
        }
        return (try? decrypt(raw.encryptedValue, key: key)) ?? raw.value
    }

    private func decrypt(_ encryptedValue: Data, key: [UInt8]) throws -> String {
        guard encryptedValue.count > 3 else {
            return String(data: encryptedValue, encoding: .utf8) ?? ""
        }

        // v10 prefix = Chrome-encrypted on macOS.
        guard encryptedValue.prefix(3) == Data("v10".utf8) else {
            return String(data: encryptedValue, encoding: .utf8) ?? ""
        }

        let ciphertext = encryptedValue.subdata(in: 3..<encryptedValue.count)
        guard !ciphertext.isEmpty else { return "" }

        // IV = 16 bytes of 0x20 (space).
        let iv = [UInt8](repeating: 0x20, count: 16)
        var decrypted = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength = 0
        let decryptedCapacity = decrypted.count

        let status: Int32 = ciphertext.withUnsafeBytes { cipherBytes -> Int32 in
            decrypted.withUnsafeMutableBytes { plainBytes -> Int32 in
                key.withUnsafeBytes { keyBytes -> Int32 in
                    iv.withUnsafeBytes { ivBytes -> Int32 in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            plainBytes.baseAddress, decryptedCapacity,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw ImportError.decryptionFailed("AES decryption failed (\(status))")
        }

        decrypted = decrypted.prefix(decryptedLength)

        // Newer Chrome versions prepend a 32-byte SHA-256 hash of the host key.
        // If the first 32 bytes aren't printable ASCII, strip them.
        if decrypted.count > 32 {
            let first32 = decrypted.prefix(32)
            let isPrintable = first32.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
            if !isPrintable {
                decrypted = decrypted.subdata(in: 32..<decrypted.count)
            }
        }

        return String(data: decrypted, encoding: .utf8) ?? ""
    }

    // MARK: - HTTPCookie construction

    private func buildHTTPCookie(from raw: RawCookie, value: String) -> HTTPCookie? {
        guard !value.isEmpty else { return nil }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: raw.name,
            .value: value,
            .domain: raw.hostKey,
            .path: raw.path.isEmpty ? "/" : raw.path,
            .secure: raw.isSecure ? "TRUE" : "FALSE"
        ]

        if let expires = expiresDate(from: raw.expiresUTC) {
            properties[.expires] = expires
        }

        return HTTPCookie(properties: properties)
    }

    /// Chrome stores expires_utc as microseconds since 1601-01-01.
    /// Convert to a Unix timestamp; return nil for already-expired cookies.
    private func expiresDate(from chromeUTC: Int64) -> Date? {
        if chromeUTC == 0 {
            // Session cookie — give it a 1-year shelf life so it persists in WKWebView.
            return Date(timeIntervalSinceNow: 365 * 24 * 60 * 60)
        }
        let unixSeconds = chromeUTC / 1_000_000 - 11_644_473_600
        if unixSeconds <= 0 { return nil } // expired
        return Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }

    // MARK: - Domain matching

    private func isXDomain(_ hostKey: String) -> Bool {
        let h = hostKey.lowercased()
        return h == "x.com" || h == ".x.com" || h.hasSuffix(".x.com")
            || h == "twitter.com" || h == ".twitter.com" || h.hasSuffix(".twitter.com")
    }

    // MARK: - Profile picker

    private func pickProfile(
        _ candidates: [(name: String, cookies: [RawCookie])]
    ) -> (name: String, cookies: [RawCookie])? {
        let sorted = candidates.sorted { $0.cookies.count > $1.cookies.count }

        let alert = NSAlert()
        alert.messageText = "Multiple Chrome profiles contain x.com cookies"
        alert.informativeText = "Select a profile to import cookies from:"
        alert.alertStyle = .informational

        for c in sorted {
            let hasAuth = c.cookies.contains { $0.name == "auth_token" } ? " \u{2713}" : ""
            alert.addButton(withTitle: "\(c.name) (\(c.cookies.count) cookies\(hasAuth))")
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0 && index < sorted.count {
            return sorted[index]
        }
        return nil
    }
}
