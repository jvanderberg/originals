import Foundation
import Security

/// Keeps the iCloud web session's cookies in the login Keychain so the sign-in survives relaunches.
///
/// WebKit's own cookie store can't be relied on for this: before a web view has been opened in the
/// current launch it reports no cookies at all, and it drops session-only cookies on quit. icloudpd
/// solves the same problem by saving the whole cookie jar, session cookies included, to its own file.
enum ICloudCookieVault {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "local.originals.Originals").icloud-session"
    private static let account = "cookies"

    /// One cookie, with just the fields iCloud's cookies use.
    private struct Stored: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> [HTTPCookie] {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        let now = Date()
        return stored.filter { $0.expires.map { $0 > now } ?? true }.compactMap(\.cookie)
    }

    @discardableResult
    static func save(_ cookies: [HTTPCookie]) -> Bool {
        guard let data = try? JSONEncoder().encode(cookies.map(Stored.init)) else { return false }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Originals iCloud sign-in"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
