import SwiftUI
import WebKit

/// Apple's own icloud.com sign-in page in a web view. Once the page has signed in, the session's
/// cookies are picked up and the sheet closes by itself.
struct ICloudSignInSheet: View {
    @Environment(ICloudWebSession.self) private var session
    @Environment(ExportManager.self) private var exporter
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.horizontal.icloud")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to iCloud for fast downloads")
                        .font(.headline)
                    Text("Photos only downloads originals from iCloud at about 0.7 MB/s. Signed in, Originals downloads them straight from iCloud, like icloud.com does. Check “Keep me signed in” to stay signed in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                let waiting = exporter.waitingForSignIn.count
                if waiting > 0 {
                    Button("Use Photos (slow)") {
                        exporter.downloadWaitingThroughPhotos()
                        dismiss()
                    }
                    .help("Download the \(waiting) waiting file\(waiting == 1 ? "" : "s") through Photos at about 0.7 MB/s")
                }
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ICloudWebView { await check() }
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 640, idealHeight: 760)
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        if await session.adoptWebKitCookies() { dismiss() }
    }
}

private struct ICloudWebView: NSViewRepresentable {
    let onCookiesChanged: @MainActor () async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookiesChanged: onCookiesChanged) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = ICloudWebSession.userAgent
        webView.navigationDelegate = context.coordinator
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: ICloudWebSession.homeURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate {
        let onCookiesChanged: @MainActor () async -> Void
        private var pending: Task<Void, Never>?

        init(onCookiesChanged: @escaping @MainActor () async -> Void) {
            self.onCookiesChanged = onCookiesChanged
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.schedule() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            schedule()
        }

        /// Cookies change many times during sign-in; check once things settle.
        private func schedule() {
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await onCookiesChanged()
            }
        }
    }
}
