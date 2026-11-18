import Foundation
import Observation
import WebKit

/// The signed-in iCloud web account: who it is and where its Photos database lives.
struct ICloudAccount: Equatable, Sendable {
    let dsid: String
    let name: String
    /// The `ckdatabasews` service root, e.g. https://p46-ckdatabasews.icloud.com:443
    let databaseURL: URL
}

enum ICloudError: LocalizedError {
    case notSignedIn
    case unexpectedResponse(String)
    case http(Int, String)
    case notInICloud
    case sizeMismatch(expected: Int64, actual: Int64)
    case noSuchVersion

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to iCloud"
        case let .unexpectedResponse(what): "Unexpected response from iCloud (\(what))"
        case let .http(status, what): "iCloud returned HTTP \(status) (\(what))"
        case .notInICloud: "This item isn't in iCloud Photos"
        case let .sizeMismatch(expected, actual): "iCloud's copy is \(actual) bytes, Photos says \(expected)"
        case .noSuchVersion: "iCloud has no smaller version of this item"
        }
    }
}

/// A web sign-in to iCloud, the same one icloud.com uses. With it, originals can be downloaded straight
/// from iCloud's servers instead of through Photos, which limits downloads to about 0.7 MB/s.
///
/// Sign-in happens on Apple's own page in a web view (see `ICloudSignInSheet`), so 2FA, passkeys and
/// "Keep me signed in" all work as they do in Safari. The resulting cookies are kept in the Keychain
/// (`ICloudCookieVault`) so the sign-in survives relaunches.
@Observable @MainActor
final class ICloudWebSession {
    static let shared = ICloudWebSession()

    enum State: Equatable {
        case unknown
        case checking
        case signedOut
        case signedIn(ICloudAccount)
        case failed(String)
    }

    private(set) var state: State = .unknown
    var isSignInPresented = false

    var account: ICloudAccount? {
        if case let .signedIn(account) = state { return account }
        return nil
    }

    /// icloud.com refuses to sign in browsers it doesn't recognize, so present as Safari.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
    static let homeURL = URL(string: "https://www.icloud.com/")!

    /// For setup.icloud.com and the Photos database: carries the iCloud cookies.
    @ObservationIgnored let apiSession: URLSession
    /// For file downloads: the download links are signed, so no cookies are sent.
    @ObservationIgnored let downloadSession: URLSession
    @ObservationIgnored private let cookieStorage: HTTPCookieStorage
    /// Set by the developer probe so a borrowed session isn't saved into the app's WebKit store.
    @ObservationIgnored var persistsCookies = true

    private init() {
        let api = URLSessionConfiguration.ephemeral
        api.httpCookieAcceptPolicy = .always
        api.httpShouldSetCookies = true
        api.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Origin": "https://www.icloud.com",
            "Referer": "https://www.icloud.com/",
        ]
        cookieStorage = api.httpCookieStorage ?? HTTPCookieStorage()
        api.httpCookieStorage = cookieStorage
        apiSession = URLSession(configuration: api)

        let downloads = URLSessionConfiguration.ephemeral
        downloads.httpCookieStorage = nil
        downloads.httpShouldSetCookies = false
        downloads.urlCache = nil
        downloads.requestCachePolicy = .reloadIgnoringLocalCacheData
        downloads.httpMaximumConnectionsPerHost = 32
        downloads.timeoutIntervalForRequest = 60
        downloadSession = URLSession(configuration: downloads)
    }

    // MARK: Signing in and out

    /// Checks the saved sign-in (called at launch).
    func refresh() async {
        state = .checking
        if persistsCookies {
            for cookie in ICloudCookieVault.load() { cookieStorage.setCookie(cookie) }
        }
        await loadCookiesFromWebKit()
        await validate(quietIfSignedOut: false)
        ExportManager.shared.signInStateChanged()
    }

    /// Called while the sign-in sheet is open whenever WebKit's cookies change.
    /// Returns true once the web page has finished signing in.
    func adoptWebKitCookies() async -> Bool {
        await loadCookiesFromWebKit()
        guard hasAuthCookie else { return false }
        return await validate(quietIfSignedOut: true)
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let apple = records.filter { $0.displayName.contains("icloud") || $0.displayName.contains("apple") }
        await store.removeData(ofTypes: types, for: apple)
        for cookie in cookieStorage.cookies ?? [] { cookieStorage.deleteCookie(cookie) }
        if persistsCookies { ICloudCookieVault.clear() }
        state = .signedOut
        ExportManager.shared.signInStateChanged()
    }

    /// iCloud rejected a request with the current cookies.
    func sessionExpired() {
        guard account != nil else { return }
        state = .signedOut
        ExportManager.shared.signInStateChanged()
    }

    #if DEBUG
    /// Developer probe only: use cookies from another client (icloudpd's saved session).
    func useCookiesForTesting(_ cookies: [HTTPCookie]) async -> Bool {
        persistsCookies = false
        for cookie in cookies { cookieStorage.setCookie(cookie) }
        return await validate(quietIfSignedOut: false)
    }
    #endif

    private var hasAuthCookie: Bool {
        (cookieStorage.cookies ?? []).contains { $0.name.hasPrefix("X-APPLE-WEBAUTH-TOKEN") }
    }

    private static func isICloudCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.domain.hasSuffix("icloud.com") || cookie.domain.hasSuffix("apple.com")
    }

    private func loadCookiesFromWebKit() async {
        guard persistsCookies else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where Self.isICloudCookie(cookie) { cookieStorage.setCookie(cookie) }
    }

    /// iCloud refreshes its session cookies on validate; save the latest ones so the next launch
    /// starts from them.
    private func saveCookies() {
        guard persistsCookies else { return }
        ICloudCookieVault.save((cookieStorage.cookies ?? []).filter(Self.isICloudCookie))
    }

    /// POST setup.icloud.com/setup/ws/1/validate (what icloud.com and icloudpd call to check a session).
    @discardableResult
    private func validate(quietIfSignedOut: Bool) async -> Bool {
        guard hasAuthCookie else {
            if !quietIfSignedOut { state = .signedOut }
            return false
        }
        var request = URLRequest(url: URL(string: "https://setup.icloud.com/setup/ws/1/validate")!)
        request.httpMethod = "POST"
        request.httpBody = Data("null".utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await apiSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if !quietIfSignedOut {
                    state = [401, 403, 421].contains(status) ? .signedOut : .failed("iCloud returned HTTP \(status)")
                }
                return false
            }
            state = .signedIn(try Self.parseAccount(data))
            saveCookies()
            ExportManager.shared.signInStateChanged()
            return true
        } catch {
            if !quietIfSignedOut { state = .failed(error.localizedDescription) }
            return false
        }
    }

    private static func parseAccount(_ data: Data) throws -> ICloudAccount {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json["dsInfo"] as? [String: Any],
              let services = json["webservices"] as? [String: Any],
              let database = services["ckdatabasews"] as? [String: Any],
              let urlString = database["url"] as? String,
              let url = URL(string: urlString) else {
            throw ICloudError.unexpectedResponse("validate")
        }
        let dsid = (info["dsid"] as? String) ?? (info["dsid"] as? NSNumber)?.stringValue ?? ""
        let name = (info["fullName"] as? String) ?? (info["appleId"] as? String) ?? "iCloud"
        return ICloudAccount(dsid: dsid, name: name, databaseURL: url)
    }
}
