import SwiftUI
import WebKit
import os

/// Full-screen ZLibrary browser using WKWebView.
///
/// Everything happens inside WebKit: login, search, browsing.
/// Cloudflare's JavaScript challenge is handled natively by the browser engine.
/// Downloads are intercepted by detecting file responses in the navigation
/// delegate, extracting the final CDN URL (with auth tokens), then using
/// URLSession to download the file directly.
struct ZLibraryBrowserView: UIViewRepresentable {
    let startURL: URL
    let onDownloadComplete: (URL, String) -> Void
    var onDownloadStart: (String) -> Void = { _ in }
    var onDownloadProgress: (Double) -> Void = { _ in }
    var onDownloadError: (String) -> Void = { _ in }
    var onLoadingStateChanged: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let script = WKUserScript(
            source: ZLibraryBrowserView.downloadInterceptorJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator, name: "downloadTriggered")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // JavaScript injected on every page load to intercept download clicks.
    // Resolves relative URLs, prevents event bubbling, and debounces.
    static let downloadInterceptorJS = """
    (function() {
        if (window.__kindredDownloadBound) return;
        window.__kindredDownloadBound = true;

        var lastClickTime = 0;

        function sendDownloadURL(url, filename) {
            if (!url || url.length === 0) return;
            // Resolve relative URLs against current page
            try {
                url = new URL(url, window.location.href).href;
            } catch(e) { return; }
            // Debounce: ignore clicks within 1 second of the last one
            var now = Date.now();
            if (now - lastClickTime < 1000) return;
            lastClickTime = now;
            window.webkit.messageHandlers.downloadTriggered.postMessage({
                url: url, filename: filename || ''
            });
        }

        document.addEventListener('click', function(e) {
            var el = e.target;
            while (el && el !== document.body) {
                if (el.tagName === 'A' && el.href) {
                    var href = el.href;
                    var cls = el.className || '';
                    if (href.indexOf('/dl/') !== -1 ||
                        cls.indexOf('addDownloadedBook') !== -1 ||
                        cls.indexOf('downloadLink') !== -1 ||
                        el.getAttribute('data-action') === 'download') {
                        e.preventDefault();
                        e.stopPropagation();
                        sendDownloadURL(href, el.getAttribute('download') || '');
                        return;
                    }
                }
                el = el.parentElement;
            }
        }, true);

        var origOpen = window.open;
        window.open = function(url) {
            if (url && url.indexOf('/dl/') !== -1) {
                sendDownloadURL(url, '');
                return null;
            }
            return origOpen.apply(window, arguments);
        };
    })();
    """

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: ZLibraryBrowserView
        weak var webView: WKWebView?
        private let logger = Logger(
            subsystem: "space.kev1nweng.kindred",
            category: "ZLibraryBrowser"
        )

        /// True while the WebView is navigating to a /dl/ URL to resolve
        /// the final CDN download link.
        private var isDownloadNavigation = false

        init(parent: ZLibraryBrowserView) {
            self.parent = parent
        }

        // MARK: - Script message handler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "downloadTriggered",
               let body = message.body as? [String: String],
               let urlString = body["url"],
               let url = URL(string: urlString) {
                logger.info("JS download triggered: \(urlString, privacy: .public)")
                // Load the /dl/ URL in the main WebView to follow
                // redirects through Cloudflare to the CDN.
                isDownloadNavigation = true
                webView?.load(URLRequest(url: url))
            }
        }

        // MARK: - Navigation

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.onLoadingStateChanged(true) }
        }

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "nil"
            logger.info("didFinish: \(url, privacy: .public)")
            webView.evaluateJavaScript(ZLibraryBrowserView.downloadInterceptorJS)
            isDownloadNavigation = false
            DispatchQueue.main.async { self.parent.onLoadingStateChanged(false) }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            logger.info("didFailProvisionalNavigation: \(error.localizedDescription, privacy: .public)")
            // If a download navigation fails, it might be because the response
            // was intercepted (canceled) in decidePolicyFor. This is expected.
            // Don't call goBack() — the page is still on the previous URL.
            isDownloadNavigation = false
            DispatchQueue.main.async { self.parent.onLoadingStateChanged(false) }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            isDownloadNavigation = false
            DispatchQueue.main.async { self.parent.onLoadingStateChanged(false) }
        }

        // Detect file responses, extract the final CDN URL, cancel navigation,
        // and download using URLSession.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let response = navigationResponse.response
            let url = response.url?.absoluteString ?? ""
            let mimeType = response.mimeType ?? ""
            let contentDisposition = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition") ?? ""

            let isDownloadURL = url.contains("/dl/")
            let hasAttachment = contentDisposition.lowercased().contains("attachment")
            let isFileResponse = !mimeType.isEmpty &&
                !mimeType.contains("text/html") &&
                !mimeType.contains("text/css") &&
                !mimeType.contains("javascript") &&
                !mimeType.contains("image/") &&
                !mimeType.contains("font")

            if isDownloadURL || hasAttachment || (isFileResponse && navigationResponse.isForMainFrame) {
                logger.info("file response: url=\(url, privacy: .public) mime=\(mimeType, privacy: .public)")

                // Extract filename from Content-Disposition header.
                // The header may contain both:
                //   filename="book.pdf"
                //   filename*=UTF-8''%E5%87%BA%E6%B5%B7.pdf
                // Prefer the RFC 5987 encoded filename* parameter.
                var filename = ""
                if let starRange = contentDisposition.range(of: "filename*=", options: .caseInsensitive) {
                    // Take value after filename*= until ; or end
                    let after = String(contentDisposition[starRange.upperBound...])
                    // Strip charset prefix like "UTF-8''"
                    let value = after.split(separator: ";", maxSplits: 1).first ?? after[...]
                    if let quoteIdx = value.range(of: "''") {
                        let encoded = String(value[quoteIdx.upperBound...]).trimmingCharacters(in: .whitespaces)
                        filename = encoded.removingPercentEncoding ?? String(encoded)
                    } else {
                        filename = String(value).trimmingCharacters(in: .whitespaces).removingPercentEncoding ?? String(value)
                    }
                }
                if filename.isEmpty {
                    // Fall back to filename="..." (quoted) or filename=... (unquoted)
                    if let range = contentDisposition.range(of: "filename=", options: .caseInsensitive) {
                        let after = String(contentDisposition[range.upperBound...])
                        // Stop at ; to avoid capturing filename* parameter
                        let raw = after.split(separator: ";", maxSplits: 1).first ?? after[...]
                        filename = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                            .removingPercentEncoding ?? String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                    }
                }
                if filename.isEmpty {
                    filename = response.suggestedFilename ?? ""
                }
                if filename.isEmpty, let u = response.url {
                    filename = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
                }
                // Clean up ZLibrary metadata from filename
                filename = filename
                    .replacingOccurrences(of: " (z-library.sk, 1lib.sk, z-lib.sk)", with: "")
                    .replacingOccurrences(of: "(z-library.sk, 1lib.sk, z-lib.sk)", with: "")
                    .trimmingCharacters(in: .whitespaces)

                isDownloadNavigation = false
                decisionHandler(.cancel)

                // If a download link returns HTML, the server is likely
                // redirecting to a login or error page instead of the file.
                if mimeType.contains("text/html") {
                    DispatchQueue.main.async {
                        self.parent.onDownloadError(String(localized: "The download link returned a webpage. Please log in to Z-Library, check your network, or try again later."))
                    }
                    return
                }

                if let fileURL = response.url {
                    DispatchQueue.main.async { self.parent.onDownloadStart(filename) }
                    downloadWithURLSession(url: fileURL, filename: filename, from: webView)
                }
            } else {
                decisionHandler(.allow)
            }
        }

        // MARK: - URLSession download

        private func downloadWithURLSession(url: URL, filename: String, from webView: WKWebView) {
            logger.info("URLSession download: \(filename, privacy: .public) from \(url.host ?? "", privacy: .public)")

            let dataStore = webView.configuration.websiteDataStore
            dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }

                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 300

                let cookieHeader = cookies
                    .filter { $0.domain.contains(url.host ?? "") || url.host?.contains($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                var request = URLRequest(url: url)
                request.setValue(
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                    forHTTPHeaderField: "User-Agent"
                )
                if !cookieHeader.isEmpty {
                    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                }

                let delegate = DownloadProgressDelegate(
                    filename: filename,
                    onProgress: { progress in
                        DispatchQueue.main.async {
                            self.parent.onDownloadProgress(progress)
                        }
                    },
                    onComplete: { finalURL in
                        // The delegate already moved the file to its final location.
                        // Just use it directly — no second move needed.
                        let title = (filename as NSString).deletingPathExtension
                        self.logger.info("download complete: \(filename, privacy: .public)")
                        DispatchQueue.main.async {
                            self.parent.onDownloadComplete(finalURL, title)
                        }
                    },
                    onError: { error in
                        self.logger.error("download failed: \(error.localizedDescription, privacy: .public)")
                        DispatchQueue.main.async {
                            self.parent.onDownloadError(error.localizedDescription)
                        }
                    }
                )

                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                task.resume()
            }
        }
    }
}

// MARK: - URLSession Download Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let filename: String
    let onProgress: (Double) -> Void
    let onComplete: (URL) -> Void
    let onError: (Error) -> Void

    init(filename: String,
         onProgress: @escaping (Double) -> Void,
         onComplete: @escaping (URL) -> Void,
         onError: @escaping (Error) -> Void) {
        self.filename = filename
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(1.0, progress))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move temp file to a stable location immediately
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZLibraryDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let stableURL = tempDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: stableURL)
        try? FileManager.default.moveItem(at: location, to: stableURL)
        onComplete(stableURL)
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            onError(error)
        }
        session.finishTasksAndInvalidate()
    }
}