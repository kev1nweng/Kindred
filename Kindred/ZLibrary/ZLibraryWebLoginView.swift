import SwiftUI
import WebKit
import os

/// A WKWebView-based login flow for ZLibrary.
///
/// ZLibrary is behind Cloudflare's JavaScript challenge, so a plain
/// HTTP client cannot authenticate. This view loads the real login
/// page in WebKit, lets the user log in normally, then extracts the
/// session cookies (`remix_userid`, `remix_userkey`) for use by
/// `ZLibraryClient`'s URLSession-based API calls.
struct ZLibraryWebLoginView: UIViewRepresentable {
    let loginURL: URL
    let onCookiesExtracted: ([HTTPCookie]) -> Void
    let onError: (String) -> Void

    // ZLibrary domains that may set cookies across mirrors
    private let cookieDomains = [
        "z-lib.pub", "z-library.im",
        ".z-lib.pub", ".z-library.im",
    ]

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: ZLibraryWebLoginView
        private var hasExtracted = false
        private let logger = Logger(
            subsystem: "space.kev1nweng.kindred",
            category: "ZLibraryWebView"
        )

        init(parent: ZLibraryWebLoginView) {
            self.parent = parent
        }

        // Log every navigation action — this captures the full redirect chain
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? "nil"
            let type = navigationAction.navigationType
            let typeName: String
            switch type {
            case .linkActivated: typeName = "linkActivated"
            case .formSubmitted: typeName = "formSubmitted"
            case .backForward: typeName = "backForward"
            case .reload: typeName = "reload"
            case .formResubmitted: typeName = "formResubmitted"
            case .other: typeName = "other"
            @unknown default: typeName = "unknown(\(type.rawValue))"
            }
            logger.info("decidePolicyFor: \(typeName, privacy: .public) -> \(url, privacy: .public)")

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "nil"
            logger.info("didStartProvisionalNavigation: \(url, privacy: .public)")
            extractCookies(from: webView)
        }

        func webView(_ webView: WKWebView,
                     didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "nil"
            logger.info("SERVER REDIRECT -> \(url, privacy: .public)")
        }

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "nil"
            logger.info("didFinish: \(url, privacy: .public)")
            extractCookies(from: webView)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse {
                let url = http.url?.absoluteString ?? "nil"
                let location = http.value(forHTTPHeaderField: "Location") ?? ""
                if !location.isEmpty {
                    logger.info("HTTP \(http.statusCode, privacy: .public) Location: \(location, privacy: .public)  (from \(url, privacy: .public))")
                } else if http.statusCode >= 300 {
                    logger.info("HTTP \(http.statusCode, privacy: .public) (from \(url, privacy: .public))")
                }
            }
            decisionHandler(.allow)
        }

        private func extractCookies(from webView: WKWebView) {
            guard !hasExtracted else { return }

            let store = webView.configuration.websiteDataStore.httpCookieStore

            store.getAllCookies { [weak self] cookies in
                guard let self else { return }

                // Log all potentially relevant cookies
                for c in cookies {
                    if c.name.contains("remix") || c.name.contains("session") || c.name.contains("auth") || c.name.contains("c_token") {
                        self.logger.info("cookie: \(c.name, privacy: .public)=\(String(c.value.prefix(12)), privacy: .public) domain=\(c.domain, privacy: .public)")
                    }
                }

                // Look for remix_userid and remix_userkey cookies
                let remixCookies = cookies.filter {
                    $0.name == "remix_userid" || $0.name == "remix_userkey"
                }

                guard remixCookies.count >= 2 else { return }

                // Grab all cookies from ZLibrary domains for completeness
                let zLibCookies = cookies.filter { cookie in
                    self.parent.cookieDomains.contains { domain in
                        cookie.domain.hasSuffix(domain)
                    }
                }

                self.logger.info("Cookies extracted (\(zLibCookies.count, privacy: .public) total), calling callback")
                self.hasExtracted = true

                DispatchQueue.main.async {
                    self.parent.onCookiesExtracted(zLibCookies)
                }
            }
        }
    }
}