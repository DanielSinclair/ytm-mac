import AppKit
import SwiftUI
import WebKit

/// First-run sheet: pick the browser to copy the YouTube login from, *before*
/// macOS shows its Keychain prompt for that browser's "Safe Storage" key.
@MainActor
enum Onboarding {
    enum Reason { case firstRun, signedOut }

    /// Presents the sheet on `window`. Returns true once a login was imported.
    static func present(on window: NSWindow, cookies: CookieImport, store: WKHTTPCookieStore,
                        reason: Reason = .firstRun) async -> Bool {
        await withCheckedContinuation { continuation in
            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            let finish = { (imported: Bool) in
                window.endSheet(sheet)
                continuation.resume(returning: imported)
            }
            sheet.contentViewController = NSHostingController(rootView: BrowserPickerView(
                reason: reason,
                sources: cookies.sources,
                initialSelection: cookies.lastSource?.id ?? cookies.sources.first?.id,
                importLogin: { try await cookies.importSession(from: $0, into: store) },
                finish: finish))
            window.beginSheet(sheet)
        }
    }
}

private struct BrowserPickerView: View {
    let reason: Onboarding.Reason
    let sources: [CookieImport.Source]
    let initialSelection: CookieImport.Source.ID?
    let importLogin: (CookieImport.Source) async throws -> Void
    let finish: (Bool) -> Void

    @State private var selection: CookieImport.Source.ID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason == .firstRun ? "Sign in with your browser" : "You've been signed out")
                        .font(.title2.bold())
                    Text(reason == .firstRun
                         ? "Reuse the YouTube login from a browser you already use."
                         : "Your session expired. Import the latest login from your browser to continue.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if sources.isEmpty {
                Text("No supported browsers found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(sources, selection: $selection) { source in
                    HStack(spacing: 10) {
                        Image(nsImage: source.icon).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.browserName)
                            if showsProfile(source) {
                                Text(source.profileName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if source.isDefaultBrowser {
                            Text("Default").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(source.id)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: min(CGFloat(sources.count) * 44 + 8, 240))
            }

            Text(reason == .firstRun
                 ? "Next, macOS asks for your login keychain password so the app can read that browser's cookies. Choose **Always Allow** so it only asks once."
                 : "If this keeps happening, open YouTube in that browser once so it refreshes its login, then import again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Sign In Manually") { finish(false) }
                    .disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(reason == .firstRun ? "Continue" : "Import Login", action: importSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || busy)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { selection = initialSelection }
    }

    private func showsProfile(_ source: CookieImport.Source) -> Bool {
        sources.filter { $0.browserName == source.browserName }.count > 1
    }

    private func importSelected() {
        guard let source = sources.first(where: { $0.id == selection }) else { return }
        busy = true
        error = nil
        Task {
            do {
                try await importLogin(source)
                finish(true)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}
