import AppKit
import OSLog
import SwiftUI
import WebKit

/// Renders a generated preview document or a real HTML file.
///
/// - The view stays transparent until the first paint finishes, so there is never a white frame
///   (user 2026-09-04); `onReady` fires then, so the pane can drop its loading state.
/// - A live HTML file runs its JavaScript and may load remote assets, and may follow links to other files
///   inside its own folder (user 2026-09-03). http(s)/mailto links open in the system browser instead;
///   everything else is cancelled — the pane never becomes a browser at some other origin.
/// - Non-persistent web data: previews keep no cookies or cache.
struct WebPreview: NSViewRepresentable {
    enum Source: Equatable {
        case file(URL)
        case html(String)
    }

    let source: Source
    /// Changes whenever a different file is shown, so identical contents still reload.
    let token: String
    let onReady: () -> Void

    init(source: Source, token: String, onReady: @escaping () -> Void) {
        self.source = source
        self.token = token
        self.onReady = onReady
    }

    static let externallyOpenableSchemes: Set<String> = ["http", "https", "mailto"]

    static func isExternallyOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return externallyOpenableSchemes.contains(scheme)
    }

    /// The trailing separator matters: "/a/bc" is not inside "/a/b".
    static func isInside(_ url: URL, directory: URL) -> Bool {
        let base = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = Palette.surface.nsColor
        webView.alphaValue = 0
        context.coordinator.onReady = onReady
        context.coordinator.load(source, token: token, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        guard context.coordinator.loadedToken != token || context.coordinator.loadedSource != source else { return }
        context.coordinator.load(source, token: token, into: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private static let log = Logger(subsystem: "com.eugenecheng.formora", category: "WebPreview")

        var onReady: () -> Void = {}
        private(set) var loadedToken: String?
        private(set) var loadedSource: Source?
        private var allowedDirectory: URL?

        func load(_ source: Source, token: String, into webView: WKWebView) {
            loadedToken = token
            loadedSource = source
            switch source {
            case .file(let url):
                let directory = url.deletingLastPathComponent()
                allowedDirectory = directory
                webView.loadFileURL(url, allowingReadAccessTo: directory)
            case .html(let html):
                allowedDirectory = nil
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            if url.absoluteString == "about:blank" { return decisionHandler(.allow) }
            if url.isFileURL, let directory = allowedDirectory, WebPreview.isInside(url, directory: directory) {
                return decisionHandler(.allow)
            }
            if navigationAction.navigationType == .linkActivated, WebPreview.isExternallyOpenable(url) {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            Self.log.info("Blocked preview navigation to \(url.absoluteString, privacy: .public)")
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reveal(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error, in: webView)
        }

        private func reveal(_ webView: WKWebView) {
            webView.alphaValue = 1
            onReady()
        }

        /// A failed load shows a readable page instead of a blank pane; a navigation we cancelled on
        /// purpose is not a failure.
        private func report(_ error: Error, in webView: WKWebView) {
            let nsError = error as NSError
            let cancelled = nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
            guard !cancelled else { return reveal(webView) }
            Self.log.error("Preview load failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            let detail = PreviewHTML.escapeText("\(nsError.localizedDescription)\n\(nsError.domain) \(nsError.code)")
            webView.loadHTMLString("""
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <style>html,body{margin:0;padding:24px;background:#131316;color:#8A8C91;font:13px -apple-system,sans-serif;line-height:1.6}
            .t{color:#E8695C;font-weight:600;margin-bottom:8px}pre{font:11.5px ui-monospace,Menlo,monospace;color:#55575C;white-space:pre-wrap;margin:0}</style>
            </head><body><div class="t">这个页面没能加载</div><pre>\(detail)</pre></body></html>
            """, baseURL: nil)
        }
    }
}
