import Foundation

/// Helpers shared by the generated preview documents.
enum PreviewHTML {
    /// Escapes text for an HTML text node.
    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A JSON value is also a valid JavaScript literal. Every `<` is additionally escaped as `<`
    /// so the HTML tokenizer never sees `</script`, `<!--` or `<script` inside our script element —
    /// the string's runtime value is unchanged (fix carried over from the old app's XSS review).
    static func jsLiteral(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [])) ?? Data("[null]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[null]"
        return String(array.dropFirst().dropLast()).replacingOccurrences(of: "<", with: "\\u003C")
    }

    static let scrollbarCSS = """
    ::-webkit-scrollbar { width: 9px; height: 9px; }
    ::-webkit-scrollbar-thumb { background: #322F35; border-radius: 5px; }
    ::-webkit-scrollbar-track { background: transparent; }
    """
}

/// Highlighted source code. The source is escaped into a `<code>` text node and highlight.js only reads
/// `textContent`, so previewing a `.js` or `.html` file never executes it. `default-src 'none'`: no disk,
/// no network, even if escaping ever regressed.
enum CodeDocument {
    static func build(source: String, languageID: String?) -> String {
        let highlight = languageID != nil
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>
        \(PreviewResources.syntaxTheme)
        html, body { margin: 0; padding: 0; background: #131316; color: #F1F1EF; }
        pre { margin: 0; padding: 18px 20px; }
        code { font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
               font-size: 12px; line-height: 1.6; white-space: pre; tab-size: 4; color: #F1F1EF; }
        \(PreviewHTML.scrollbarCSS)
        </style></head>
        <body><pre><code class="\(highlight ? "language-\(languageID!)" : "nohighlight")">\(PreviewHTML.escapeText(source))</code></pre>
        \(highlight ? "<script>\(PreviewResources.highlightScript)</script><script>hljs.highlightAll();</script>" : "")
        </body></html>
        """
    }
}

/// A Markdown file rendered by marked, with raw HTML escaped (shown as text, never executed) and link /
/// image URLs escaped for attribute context. Local images inside the project are inlined as data URIs
/// by Swift, so the page itself never gets disk access.
enum MarkdownDocument {
    static let maxInlineImageBytes = 2_000_000
    private static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                     "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml"]

    static func build(source: String, fileURL: URL?, projectRoot: URL?) -> String {
        let images = inlineImages(in: source, fileURL: fileURL, projectRoot: projectRoot)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src https: data:">
        <style>
        \(PreviewResources.syntaxTheme)
        \(stylesheet)
        </style></head>
        <body><article id="doc"></article>
        <script>\(PreviewResources.markedScript)</script>
        <script>\(PreviewResources.highlightScript)</script>
        <script>
        (function () {
          const source = \(PreviewHTML.jsLiteral(source));
          const localImages = \(PreviewHTML.jsLiteral(images));
          // Text-node escaping and attribute escaping are different contexts; merging them caused an
          // XSS in the old app (a quote closing href/src early). Keep them separate.
          function escapeHTML(s) {
            return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
          }
          function escapeAttribute(s) {
            return escapeHTML(s).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
          }
          const SAFE_URL = /^(https?:|mailto:|#)/i;
          function localImage(href) {
            if (localImages[href]) { return localImages[href]; }
            try { return localImages[decodeURI(href)] || null; } catch (e) { return null; }
          }
          marked.use({
            renderer: {
              html(token) { return escapeHTML(token.text || token.raw || ""); },
              link(token) {
                const href = String(token.href || "");
                const text = this.parser.parseInline(token.tokens);
                if (!SAFE_URL.test(href)) { return text; }
                return '<a href="' + escapeAttribute(href) + '">' + text + "</a>";
              },
              image(token) {
                const href = String(token.href || "");
                const alt = escapeAttribute(token.text || "");
                const inlined = localImage(href);
                if (inlined) { return '<img src="' + inlined + '" alt="' + alt + '">'; }
                if (!/^https:/i.test(href)) { return alt; }
                return '<img src="' + escapeAttribute(href) + '" alt="' + alt + '">';
              },
            },
          });
          document.getElementById("doc").innerHTML = marked.parse(source);
          document.querySelectorAll("pre code").forEach(function (block) { hljs.highlightElement(block); });
        })();
        </script>
        </body></html>
        """
    }

    /// `![alt](relative/path.png)` → data URI, for images inside the project folder only.
    static func inlineImages(in source: String, fileURL: URL?, projectRoot: URL?) -> [String: String] {
        guard let fileURL, let projectRoot else { return [:] }
        let rootPath = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [String: String] = [:]
        for match in source.matches(of: /!\[[^\]]*\]\(\s*<?([^)\s>]+)>?/) {
            let href = String(match.output.1)
            guard result[href] == nil, !href.contains(":"), !href.hasPrefix("#") else { continue }
            let relative = href.removingPercentEncoding ?? href
            let target = URL(fileURLWithPath: relative, relativeTo: fileURL.deletingLastPathComponent())
                .standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(rootPath + "/"),
                  let mime = imageTypes[target.pathExtension.lowercased()],
                  let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maxInlineImageBytes,
                  let data = try? Data(contentsOf: target) else { continue }
            result[href] = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return result
    }

    private static let stylesheet = """
    html, body { margin: 0; padding: 0; background: #09090B; color: #F1F1EF; }
    #doc { max-width: 760px; padding: 24px 28px 80px;
           font-family: "Sora", -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif;
           font-size: 14px; line-height: 1.75; }
    #doc > *:first-child { margin-top: 0; }
    h1, h2, h3, h4, h5, h6 { color: #F1F1EF; font-weight: 700; line-height: 1.3; margin: 1.8em 0 0.6em; }
    h1 { font-size: 25px; }
    h2 { font-size: 20px; padding-bottom: 0.3em; border-bottom: 1px solid #201F23; }
    h3 { font-size: 17px; }
    h4, h5, h6 { font-size: 14.5px; color: #8A8C91; }
    p { margin: 0 0 1.1em; }
    a { color: #8B93F8; text-decoration: none; }
    a:hover { text-decoration: underline; }
    strong { color: #F1F1EF; font-weight: 650; }
    ul, ol { margin: 0 0 1.1em; padding-left: 1.6em; }
    li { margin: 0.3em 0; }
    li::marker { color: #55575C; }
    input[type=checkbox] { accent-color: #8B93F8; margin-right: 6px; }
    /* Task items show the checkbox in the bullet's place, not a bullet and a checkbox (GitHub's look).
       marked puts the box directly in the <li>, or in its first <p> when the list is loose. */
    li:has(> input[type=checkbox]:first-child), li:has(> p:first-child > input[type=checkbox]:first-child) { list-style: none; }
    li > input[type=checkbox]:first-child, li > p:first-child > input[type=checkbox]:first-child { margin: 0 0.45em 0 -1.4em; }
    blockquote { margin: 0 0 1.1em; padding: 2px 0 2px 16px; border-left: 3px solid #322F35; color: #8A8C91; }
    blockquote > *:last-child { margin-bottom: 0; }
    hr { border: none; border-top: 1px solid #201F23; margin: 2em 0; }
    code { font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
    :not(pre) > code { background: #1C1D20; color: #7FD1F0; padding: 2px 6px; border-radius: 5px; }
    pre { margin: 0 0 1.1em; padding: 14px 16px; background: #131316; border: 1px solid #201F23;
          border-radius: 10px; overflow-x: auto; }
    pre code { font-size: 12px; line-height: 1.6; }
    table { border-collapse: collapse; margin: 0 0 1.3em; width: 100%; font-size: 13px; }
    th, td { border: 1px solid #201F23; padding: 8px 12px; text-align: left; }
    th { background: #1C1D20; color: #F1F1EF; font-weight: 600; }
    td { color: #8A8C91; }
    tr:nth-child(even) td { background: #131316; }
    img { max-width: 100%; border-radius: 8px; }
    \(PreviewHTML.scrollbarCSS)
    """
}
