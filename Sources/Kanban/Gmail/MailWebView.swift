import SwiftUI
import WebKit

/// Renders one sanitized message body. Remote content is blocked by policy and by a
/// CSP meta tag; JavaScript is enabled only for the height reporter, and the HTML
/// that reaches the view has already had scripts and handlers stripped.
struct MailHTMLView: NSViewRepresentable {
    var html: String?
    var plainText: String
    var isDark: Bool
    var inlineImages: [String: Data]
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "height")
        let script = """
            (function(){
              function report(){
                var h = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
                window.webkit.messageHandlers.height.postMessage(h);
              }
              window.addEventListener('load', report);
              setTimeout(report, 120);
              if (window.ResizeObserver) { new ResizeObserver(report).observe(document.body); }
            })();
            """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.isInspectable = false
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = MailHTMLDocument.make(
            html: html, plainText: plainText, isDark: isDark,
            inlineImages: inlineImages)
        guard context.coordinator.lastDocument != document else { return }
        context.coordinator.lastDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MailHTMLView
        var lastDocument: String?

        init(_ parent: MailHTMLView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["about", "data"].contains(scheme) {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "height",
                  let value = message.body as? NSNumber else { return }
            let newHeight = max(60, min(1_200, CGFloat(truncating: value)))
            if abs(parent.height - newHeight) > 2 {
                DispatchQueue.main.async {
                    self.parent.height = newHeight
                }
            }
        }
    }
}

/// Wraps a message in a neutral document. Inline styles are kept because marketing
/// mail depends on them; colours are nudged only where the sender set black text.
enum MailHTMLDocument {
    static func make(html: String?, plainText: String, isDark: Bool,
                     inlineImages: [String: Data]) -> String {
        let body: String
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var sanitized = GmailMime.sanitizeHTML(html)
            sanitized = GmailMime.inline(sanitized, images: inlineImages)
            body = sanitized
        } else {
            body = plainText
                .components(separatedBy: "\n")
                .map { "<p>\(escape($0))</p>" }
                .joined()
        }
        let ink = isDark ? "#e7eadf" : "#15170f"
        let inkSecondary = isDark ? "#9aa08d" : "#555b4e"
        let line = isDark ? "#484d3e" : "#a8ae9d"
        let signal = isDark ? "#d9785f" : "#a03b2b"
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none';">
            <style>
            :root { color-scheme: \(isDark ? "dark" : "light"); }
            html,body { margin:0; padding:0; background:transparent; }
            body { color:\(ink); font:13px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                   word-wrap:break-word; overflow-wrap:anywhere; }
            a { color:\(ink); text-decoration:underline; }
            \(isDark ? "p,div,span,table,tr,td,th,li,h1,h2,h3,h4,h5,h6,blockquote,pre,code { color:\(ink) !important; background-color:transparent !important; }" : "")
            blockquote { margin:10px 0 10px 12px; padding-left:12px; border-left:2px solid \(line); color:\(inkSecondary); }
            img { max-width:100%; height:auto; }
            table { max-width:100%; border-collapse:collapse; }
            td,th { padding:2px 4px; }
            pre,code { font-family: ui-monospace, Menlo, monospace; font-size:12px; white-space:pre-wrap; }
            .blocked-image { display:inline-block; padding:2px 6px; border:1px dashed \(line);
                             border-radius:4px; color:\(inkSecondary); font-size:11px; }
            hr { border:0; border-top:1px solid \(line); }
            .meet-signature { color:\(signal); }
            </style></head><body>\(body)</body></html>
            """
    }

    private static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
