import AppKit
import SweetCookieKit
import WebKit

/// Copies an existing YouTube/Google login from an installed browser into the
/// app's WebKit cookie store (via SweetCookieKit), so you never sign in here.
@MainActor
final class CookieImport {
    /// One browser profile (which may have several cookie stores, e.g. Chromium "Network").
    struct Source: Identifiable, Hashable {
        let id: String
        let browserName: String
        let profileName: String
        let icon: NSImage
        let isDefaultBrowser: Bool
        let stores: [BrowserCookieStore]
    }

    enum ImportError: LocalizedError {
        case noLogin(String)
        case unreadable(String, Error)
        var errorDescription: String? {
            switch self {
            case .noLogin(let name): "No YouTube login found in \(name). Sign in to YouTube there first, or pick another browser."
            case .unreadable(let name, let error): "Couldn't read cookies from \(name): \(error.localizedDescription)"
            }
        }
    }

    let sources: [Source]
    private let query = BrowserCookieQuery(domains: ["youtube.com", "google.com"], domainMatch: .suffix)

    init() {
        let browsers = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://")!)
        let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!)
        func app(for name: String) -> URL? {
            browsers.first { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(name) }
        }

        var grouped: [(key: String, stores: [BrowserCookieStore])] = []
        for store in BrowserCookieClient().stores(in: Browser.defaultImportOrder) {
            let key = "\(store.browser)|\(store.profile.id)"
            if let i = grouped.firstIndex(where: { $0.key == key }) { grouped[i].stores.append(store) }
            else { grouped.append((key, [store])) }
        }
        sources = grouped.compactMap { key, stores in
            let browser = stores[0].browser
            let appURL = app(for: browser.displayName)
            guard browser == .safari || appURL != nil else { return nil } // profile left behind by an uninstalled browser
            return Source(
                id: key, browserName: browser.displayName, profileName: stores[0].profile.name,
                icon: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.networkName)!,
                isDefaultBrowser: appURL != nil && appURL?.standardizedFileURL == defaultBrowser?.standardizedFileURL,
                stores: stores)
        }
        .sorted { $0.isDefaultBrowser && !$1.isDefaultBrowser }
    }

    /// A session cookie that is actually sent to music.youtube.com.
    private nonisolated static func isSession(_ c: HTTPCookie) -> Bool {
        ["SAPISID", "__Secure-3PSID"].contains(c.name) && (c.domain == ".youtube.com" || c.domain == "music.youtube.com")
    }

    func hasSession(in store: WKHTTPCookieStore) async -> Bool {
        await store.allCookies().contains(where: Self.isSession)
    }

    /// Reads the profile's YouTube/Google cookies and installs them. With `interactive: false`
    /// the import fails instead of showing a Keychain prompt (for silent background re-login).
    func importSession(from source: Source, into target: WKHTTPCookieStore, interactive: Bool = true) async throws {
        let query = query
        let result: Result<[HTTPCookie], Error> = await Task.detached {
            Result {
                let read = {
                    let client = BrowserCookieClient()
                    return try source.stores.flatMap { try client.records(matching: query, in: $0) }.compactMap(Self.cookie)
                }
                return try interactive ? read() : BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(read)
            }
        }.value
        let label = source.profileName.isEmpty ? source.browserName : "\(source.browserName) (\(source.profileName))"
        let cookies: [HTTPCookie]
        switch result {
        case .success(let c): cookies = c
        case .failure(let error): throw ImportError.unreadable(label, error)
        }
        guard cookies.contains(where: Self.isSession) else { throw ImportError.noLogin(label) }

        for old in await target.allCookies()
        where old.domain.hasSuffix("youtube.com") || old.domain.hasSuffix("google.com") {
            await target.deleteCookie(old)
        }
        for c in cookies { await target.setCookie(c) }
        UserDefaults.standard.set(source.id, forKey: "LoginSource")
    }

    /// The browser profile the last successful import came from.
    var lastSource: Source? {
        UserDefaults.standard.string(forKey: "LoginSource").flatMap { id in sources.first { $0.id == id } }
    }

    /// SweetCookieKit's own HTTPCookie conversion drops the leading dot of domain
    /// cookies (making `.youtube.com` host-only), so build them from the records.
    private nonisolated static func cookie(_ r: BrowserCookieRecord) -> HTTPCookie? {
        let host = r.domain.hasPrefix(".") ? String(r.domain.dropFirst()) : r.domain
        guard !host.isEmpty else { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: r.scope == .domain ? "." + host : host,
            .path: r.path.isEmpty ? "/" : r.path,
            .name: r.name,
            .value: r.value,
        ]
        if r.isSecure { props[.secure] = "TRUE" }
        if r.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = r.expires { props[.expires] = expires }
        return HTTPCookie(properties: props)
    }
}
