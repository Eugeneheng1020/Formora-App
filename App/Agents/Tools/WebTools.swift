import AppKit
import Foundation

/// The web (7c, C4–C6): fetch reads a page as text, web_search finds pages, open_url shows one to the user. None sends
/// a login or a cookie: what they reach is the public web.
enum WebTools {
    static let readLimit = 20_000
    static let downloadLimit = 5 * 1024 * 1024
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// No cookies, no stored credentials.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    struct Problem: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// An http(s) address, or `nil`.
    static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: open_url (C6)

    static func open(arguments json: String) async -> ToolResult {
        guard let raw = ToolArguments.parse(json)?["url"] as? String, let url = webURL(raw) else {
            return .failed("只能打开 http:// 或 https:// 开头的网址")
        }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        return .done("已经在用户的浏览器里打开了 \(url.absoluteString)。你看不到页面内容；需要内容就用 fetch。")
    }

    // MARK: fetch (C4)

    static func fetch(arguments json: String) async -> ToolResult {
        guard let args = ToolArguments.parse(json) else { return .failed("参数不是合法的 JSON 对象：\(json.prefix(200))") }
        guard let raw = args["url"] as? String, let url = webURL(raw) else { return .failed("url 要是 http:// 或 https:// 开头的网址") }
        if let reason = await blockedHost(url.host ?? "") { return .failed(reason) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await session.data(for: request, delegate: RedirectGuard())
            let http = response as? HTTPURLResponse
            // A redirect the guard refused ends here, on the 3xx itself.
            if let status = http?.statusCode, (300..<400).contains(status) {
                return .failed("这个网页要跳转到 \(http?.value(forHTTPHeaderField: "Location") ?? "另一个地址")，" + localReason)
            }
            return readable(data.prefix(downloadLimit), status: http?.statusCode ?? 200,
                            contentType: http?.value(forHTTPHeaderField: "Content-Type"), url: http?.url ?? url,
                            offset: max(0, ToolArguments.int(args, "offset") ?? 0))
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return .failed("等了 30 秒没有打开这个网页：\(url.absoluteString)")
            case .cannotFindHost, .dnsLookupFailed: return .failed("找不到这个网站：\(url.host ?? url.absoluteString)")
            default: return .failed("打不开这个网页：\(error.localizedDescription)")
            }
        } catch {
            return .failed("打不开这个网页：\(error.localizedDescription)")
        }
    }

    // MARK: The public web only (review 2026-09-12)

    static let localReason = "那是本机或内网的地址（localhost、127.x、10.x、172.16–31.x、192.168.x、169.254.x 这类）。fetch 只读公开的网页，不去这些地方。"

    /// Why `host` is off limits, or `nil`: a local name, or any address it resolves to that isn't on the public
    /// internet — a page can't steer an Agent into the router, a dev server or a cloud metadata address. A name that
    /// doesn't resolve here goes on (a proxy may resolve it), and URLSession says so if it can't.
    static func blockedHost(_ host: String) async -> String? {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !name.isEmpty else { return localReason }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".internal") {
            return localReason
        }
        let addresses = await Task.detached { resolve(name) }.value
        return addresses.contains { !isPublic($0) } ? localReason : nil
    }

    /// The host's addresses as raw bytes, 4 for IPv4 and 16 for IPv6; none when it doesn't resolve.
    static func resolve(_ name: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    var raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    addresses.append(withUnsafeBytes(of: &raw) { Array($0) })
                case AF_INET6:
                    var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    addresses.append(withUnsafeBytes(of: &raw) { Array($0) })
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }

    /// Not this Mac, the local network, link-local, shared (CGNAT), multicast or unspecified. 198.18.0.0/15 stays
    /// public: a proxy's fake-IP DNS answers with it for every name.
    static func isPublic(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 16 {
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return isPublic(Array(bytes[12..<16])) }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) { return false }             // :: and ::1
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }          // fe80::/10
            if bytes[0] & 0xfe == 0xfc { return false }                            // fc00::/7
            return bytes[0] != 0xff                                                // multicast
        }
        guard bytes.count == 4 else { return false }
        let (a, b) = (bytes[0], bytes[1])
        switch a {
        case 0, 10, 127, 224...255: return false
        case 100 where b & 0xc0 == 64: return false
        case 169 where b == 254: return false
        case 172 where b & 0xf0 == 16: return false
        case 192 where b == 168: return false
        default: return true
        }
    }

    /// Each hop of a redirect is judged like the first address: a public page can't bounce the fetch inward.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, WebTools.webURL(url.absoluteString) != nil, let host = url.host,
                  await WebTools.blockedHost(host) == nil else { return nil }
            return request
        }
    }

    /// What a response says, as the model reads it: HTML as text with its title, JSON and plain text as they are,
    /// at most `limit` characters from `offset`; a login wall, a missing page or a file that isn't text, said so.
    static func readable(_ data: Data, status: Int, contentType: String?, url: URL, offset: Int = 0, limit: Int = readLimit) -> ToolResult {
        switch status {
        case 401, 403:
            return .failed("这个网页要登录或拒绝了访问（\(status)）。fetch 不带任何登录信息，读不了；可以请用户把内容复制过来，或者用 open_url 在用户的浏览器里打开。")
        case 404, 410:
            return .failed("网页不存在（\(status)）：\(url.absoluteString)")
        case 400...:
            return .failed("网站返回了 \(status)，没有拿到内容：\(url.absoluteString)")
        default:
            break
        }
        let type = (contentType ?? "").lowercased()
        if let kind = binaryKind(type) {
            return .failed("这是\(kind)，fetch 只读文字。要处理它，用 bash 把它下载进项目（curl -L -o 文件名 网址），再用对应的 Skill。")
        }
        let text = decode(data, contentType: type)
        let body: String
        if type.contains("html") || (!type.contains("json") && !type.contains("text/plain") && looksLikeHTML(text)) {
            let page = WebText.readable(text)
            body = [page.title.map { "# \($0)" }, page.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else {
            body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty else { return .done("这个网页没有能读的文字（可能要运行脚本才显示内容）：\(url.absoluteString)") }
        let total = body.count
        guard offset < total else { return .failed("offset \(offset) 超出了正文长度（共 \(total) 字）") }
        let start = body.index(body.startIndex, offsetBy: offset)
        let end = body.index(start, offsetBy: limit, limitedBy: body.endIndex) ?? body.endIndex
        let slice = body[start..<end]
        var output = "来源：\(url.absoluteString)\n\n\(slice)"
        if end < body.endIndex {
            output += "\n\n（正文共 \(total) 字，这里是第 \(offset + 1)–\(offset + slice.count) 字；用 offset=\(offset + slice.count) 接着读）"
        }
        return .done(output)
    }

    private static func binaryKind(_ type: String) -> String? {
        if type.hasPrefix("image/") { return "一张图片" }
        if type.hasPrefix("audio/") || type.hasPrefix("video/") { return "音视频文件" }
        if type.contains("application/pdf") { return "一个 PDF 文件" }
        if type.contains("officedocument") || type.contains("msword") || type.contains("ms-excel") || type.contains("ms-powerpoint") {
            return "一个 Office 文件"
        }
        if type.contains("application/zip") || type.contains("octet-stream") { return "一个二进制文件" }
        return nil
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        let start = text.prefix(1024).lowercased()
        return start.contains("<html") || start.contains("<!doctype html") || start.contains("<body")
    }

    /// The header's charset, else the page's `<meta charset>`, else UTF-8 — Chinese sites still serve GBK.
    static func decode(_ data: Data, contentType: String) -> String {
        let declared = charset(in: contentType) ?? charset(in: String(decoding: data.prefix(4096), as: UTF8.self))
        if let name = declared?.lowercased(), !["utf-8", "utf8"].contains(name) {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func charset(in text: String) -> String? {
        guard let range = text.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(text[range])
        return match.range(of: #"[A-Za-z0-9_\-]+$"#, options: .regularExpression).map { String(match[$0]) }
    }

    // MARK: web_search (C5)

    struct Hit: Equatable, Sendable {
        let title: String
        let url: String
        let snippet: String?
    }

    /// The Agent's own provider when it searches natively (Claude, Gemini, Grok); others go to DuckDuckGo.
    static func nativeSearchTarget(_ target: ChatTarget) -> ChatTarget? {
        switch target.endpoint.apiProtocol {
        case .anthropicMessages, .googleGenerativeAI: return target
        case .openAIResponses where target.providerID == "xai": return target
        default: return nil
        }
    }

    static func search(arguments json: String, native: ChatTarget?) async -> ToolResult {
        guard let args = ToolArguments.parse(json) else { return .failed("参数不是合法的 JSON 对象：\(json.prefix(200))") }
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .failed("缺少参数 query")
        }
        let count = min(max(ToolArguments.int(args, "max_results") ?? 8, 1), 15)
        var note = ""
        if let native {
            switch await nativeSearch(query, target: native) {
            case .success(let text): return .done(text)
            case .failure(let problem): note = "\(nativeLabel(native)) 的联网搜索这次没用上（\(problem.message)），改用 DuckDuckGo。\n\n"
            }
        }
        switch await duckDuckGo(query) {
        case .success(let hits):
            guard !hits.isEmpty else { return .done(note + "没有搜到和「\(query)」相关的结果，换个说法再搜。") }
            return .done(note + format(Array(hits.prefix(count)), query: query))
        case .failure(let problem):
            return .failed(note + problem.message + " 可以稍后再试，或者在「设置 → MCP」接一个搜索服务（比如 Tavily、Firecrawl）。")
        }
    }

    static func format(_ hits: [Hit], query: String) -> String {
        let lines = hits.enumerated().map { index, hit in
            var entry = "\(index + 1). \(hit.title)\n   \(hit.url)"
            if let snippet = hit.snippet, !snippet.isEmpty { entry += "\n   \(snippet)" }
            return entry
        }
        return "DuckDuckGo 搜「\(query)」的结果：\n\n" + lines.joined(separator: "\n\n") + "\n\n要看全文，用 fetch 读对应的网址。"
    }

    // MARK: DuckDuckGo (keyless, omp `duckduckgo.ts`)

    /// DuckDuckGo's two keyless pages. Each is throttled on its own (checked live 2026-09-11): after a few quick
    /// searches one answers 202 or a verification page for a while, and the other often still answers.
    enum DuckDuckGoPage: CaseIterable {
        case html, lite

        var address: String { self == .html ? "https://html.duckduckgo.com/html/" : "https://lite.duckduckgo.com/lite/" }

        func hits(_ page: String) -> [Hit] {
            self == .html ? WebTools.parseDuckDuckGo(page) : WebTools.parseDuckDuckGoLite(page)
        }
    }

    static func duckDuckGo(_ query: String) async -> Result<[Hit], Problem> {
        for page in DuckDuckGoPage.allCases {
            switch await duckDuckGo(query, page: page) {
            case .success(let hits?): return .success(hits)
            case .success(nil): continue
            case .failure(let problem): return .failure(problem)
            }
        }
        return .failure(Problem("DuckDuckGo 这会儿要求人机验证，没搜成。"))
    }

    /// The page's results, or `nil` when it's throttled.
    private static func duckDuckGo(_ query: String, page: DuckDuckGoPage) async -> Result<[Hit]?, Problem> {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "wt-wt"), URLQueryItem(name: "b", value: "")]
        var request = URLRequest(url: URL(string: page.address)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(page.address, forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(decoding: data, as: UTF8.self)
            if status == 202 || status == 429 || html.contains("anomaly-modal") || html.contains("anomaly.js") { return .success(nil) }
            guard (200..<300).contains(status) else { return .failure(Problem("DuckDuckGo 返回了 \(status)，这次没搜成。")) }
            return .success(page.hits(html))
        } catch {
            return .failure(Problem("连不上 DuckDuckGo：\(error.localizedDescription)。"))
        }
    }

    /// Results of the HTML page, ads (`result--ad`, DuckDuckGo's own links) left out.
    static func parseDuckDuckGo(_ html: String) -> [Hit] {
        var hits: [Hit] = []
        for chunk in html.components(separatedBy: "<div class=\"result ").dropFirst() {
            let classes = chunk.prefix { $0 != "\"" }
            if classes.contains("result--ad") { continue }
            guard let anchor = WebText.groups(#"(<a\b[^>]*class="result__a"[^>]*>)(.*?)</a>"#, in: chunk), anchor.count == 2,
                  let href = WebText.groups(#"href="([^"]+)""#, in: anchor[0])?.first, let url = unwrap(href),
                  !(URL(string: url)?.host ?? "").hasSuffix("duckduckgo.com") else { continue }
            let title = WebText.plain(anchor[1])
            guard !title.isEmpty else { continue }
            let snippet = WebText.groups(#"class="result__snippet"[^>]*>(.*?)</(?:a|div|span)>"#, in: chunk)?.first.map(WebText.plain)
            hits.append(Hit(title: title, url: url, snippet: snippet))
        }
        return hits
    }

    /// Results of the lite page: a table where each result is a `result-link` anchor followed by its
    /// `result-snippet` cell. Ads link through duckduckgo.com and are left out.
    static func parseDuckDuckGoLite(_ html: String) -> [Hit] {
        var hits: [Hit] = []
        for chunk in html.components(separatedBy: "<a ").dropFirst() {
            let tag = String(chunk.prefix { $0 != ">" })
            guard tag.contains("result-link"),
                  let href = WebText.groups(#"href=["']([^"']+)["']"#, in: tag)?.first, let url = unwrap(href),
                  !(URL(string: url)?.host ?? "").hasSuffix("duckduckgo.com"),
                  let title = WebText.groups(#">(.*?)</a>"#, in: chunk)?.first.map(WebText.plain), !title.isEmpty else { continue }
            let snippet = WebText.groups(#"class=["']result-snippet["'][^>]*>(.*?)</td>"#, in: chunk)?.first.map(WebText.plain)
            hits.append(Hit(title: title, url: url, snippet: snippet))
        }
        return hits
    }

    /// DuckDuckGo wraps some links in `/l/?uddg=<address>`.
    private static func unwrap(_ href: String) -> String? {
        let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
        if let range = decoded.range(of: #"[?&]uddg=([^&]+)"#, options: .regularExpression) {
            let value = decoded[range].split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            return value.removingPercentEncoding
        }
        if decoded.hasPrefix("//") { return "https:" + decoded }
        return decoded.hasPrefix("http://") || decoded.hasPrefix("https://") ? decoded : nil
    }

    // MARK: Native search (the Agent's own key, old 2026-09-09)

    private static func nativeLabel(_ target: ChatTarget) -> String {
        switch target.endpoint.apiProtocol {
        case .anthropicMessages: "Claude"
        case .googleGenerativeAI: "Gemini"
        default: "Grok"
        }
    }

    static func nativeSearch(_ query: String, target: ChatTarget) async -> Result<String, Problem> {
        let prompt = "在网上搜索并回答：\(query)\n只根据搜到的内容回答，简短、具体。"
        let path: String
        let body: [String: Any]
        switch target.endpoint.apiProtocol {
        case .anthropicMessages:
            path = "/v1/messages"
            body = ["model": target.modelID, "max_tokens": 2048, "messages": [["role": "user", "content": prompt]],
                    "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]]
        case .googleGenerativeAI:
            let model = target.modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.modelID
            path = "/models/\(model):generateContent"
            body = ["contents": [["role": "user", "parts": [["text": prompt]]]], "tools": [["google_search": [String: Any]()]]]
        case .openAIResponses where target.providerID == "xai":
            path = "/responses"
            body = ["model": target.modelID, "input": prompt, "tools": [["type": "web_search"]], "store": false]
        default:
            return .failure(Problem("这个服务商没有联网搜索"))
        }
        guard var request = target.endpoint.request(path, key: target.key),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .failure(Problem("地址无效")) }
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (reply, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return .failure(Problem("返回了 \(status)\(ProviderClient.providerMessage(from: reply).map { "：\($0)" } ?? "")"))
            }
            guard let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return .failure(Problem("回复读不出来")) }
            let (answer, sources) = nativeAnswer(json, apiProtocol: target.endpoint.apiProtocol)
            guard !answer.isEmpty else { return .failure(Problem("没有给出结果")) }
            return .success(formatNative(answer, sources: sources, label: nativeLabel(target)))
        } catch {
            return .failure(Problem(error.localizedDescription))
        }
    }

    /// The answer and the pages it came from, per protocol.
    static func nativeAnswer(_ json: [String: Any], apiProtocol: APIProtocol) -> (answer: String, sources: [Hit]) {
        var texts: [String] = []
        var sources: [Hit] = []
        func add(_ url: String?, _ title: String?) {
            guard let url, !url.isEmpty, !sources.contains(where: { $0.url == url }) else { return }
            sources.append(Hit(title: (title?.isEmpty == false ? title : nil) ?? url, url: url, snippet: nil))
        }
        switch apiProtocol {
        case .anthropicMessages:
            for block in json["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                    for citation in block["citations"] as? [[String: Any]] ?? [] { add(citation["url"] as? String, citation["title"] as? String) }
                case "web_search_tool_result":
                    for result in block["content"] as? [[String: Any]] ?? [] where result["type"] as? String == "web_search_result" {
                        add(result["url"] as? String, result["title"] as? String)
                    }
                default:
                    break
                }
            }
        case .googleGenerativeAI:
            let candidate = (json["candidates"] as? [[String: Any]])?.first
            for part in (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
                if let text = part["text"] as? String, part["thought"] as? Bool != true { texts.append(text) }
            }
            let grounding = candidate?["groundingMetadata"] as? [String: Any]
            for chunk in grounding?["groundingChunks"] as? [[String: Any]] ?? [] {
                let web = chunk["web"] as? [String: Any]
                add(web?["uri"] as? String, web?["title"] as? String)
            }
        default:
            for item in json["output"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "web_search_call" {
                    for source in (item["action"] as? [String: Any])?["sources"] as? [[String: Any]] ?? [] {
                        add(source["url"] as? String, source["title"] as? String)
                    }
                }
                guard item["type"] as? String == "message" else { continue }
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if let text = content["text"] as? String { texts.append(text) }
                    for annotation in content["annotations"] as? [[String: Any]] ?? [] where annotation["type"] as? String == "url_citation" {
                        add(annotation["url"] as? String, annotation["title"] as? String)
                    }
                }
            }
        }
        return (texts.joined().trimmingCharacters(in: .whitespacesAndNewlines), Array(sources.prefix(10)))
    }

    static func formatNative(_ answer: String, sources: [Hit], label: String) -> String {
        var text = "\(label) 联网搜索的结论：\n\(answer)"
        if !sources.isEmpty {
            text += "\n\n来源：\n" + sources.enumerated().map { "\($0.offset + 1). \($0.element.title) — \($0.element.url)" }.joined(separator: "\n")
        }
        return text + "\n\n要核对原文，用 fetch 读对应的网址。"
    }
}

/// HTML as text a model can read (C4): the title; `<main>` or `<article>` when there is one, else the body; scripts,
/// styles, navigation and footers dropped; headings, list items, paragraphs and table cells kept as lines.
enum WebText {
    static func readable(_ html: String) -> (title: String?, text: String) {
        let title = groups(#"<title\b[^>]*>(.*?)</title>"#, in: html)?.first.map(plain).flatMap { $0.isEmpty ? nil : $0 }
        var body = groups(#"<main\b[^>]*>(.*)</main>"#, in: html)?.first
            ?? groups(#"<article\b[^>]*>(.*)</article>"#, in: html)?.first
            ?? groups(#"<body\b[^>]*>(.*)</body>"#, in: html)?.first
            ?? html
        body = replace(#"<!--.*?-->"#, in: body, with: " ")
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "nav", "footer", "aside", "button", "select"] {
            body = replace(#"<\#(tag)\b[^>]*>.*?</\#(tag)>"#, in: body, with: " ")
        }
        for level in 1...6 {
            body = replace(#"<h\#(level)\b[^>]*>"#, in: body, with: "\n\n" + String(repeating: "#", count: level) + " ")
        }
        body = replace(#"<li\b[^>]*>"#, in: body, with: "\n- ")
        body = replace(#"<br\s*/?>"#, in: body, with: "\n")
        body = replace(#"</t[dh]>"#, in: body, with: " | ")
        // `<li>` already starts its own line; its closing tag adds none, so a list stays one item per line.
        body = replace(#"</?(p|div|section|article|tr|h[1-6]|blockquote|pre|table|ul|ol|dl|dd|dt|figure|header)\b[^>]*>"#, in: body, with: "\n")
        body = replace(#"<[^>]+>"#, in: body, with: "")
        let lines = decode(body).components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        return (title, kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A fragment's text on one line: tags gone, entities decoded, spaces collapsed.
    static func plain(_ html: String) -> String {
        decode(replace(#"<[^>]+>"#, in: html, with: " "))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
                                   "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&middot;": "·", "&copy;": "©",
                                   "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”", "&laquo;": "«", "&raquo;": "»"]

    static func decode(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result), let codeRange = Range(match.range(at: 1), in: result) else { continue }
                let code = result[codeRange]
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) { result.replaceSubrange(range, with: String(Character(scalar))) }
            }
        }
        for (entity, character) in entities { result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive) }
        // Last, so `&amp;lt;` reads `&lt;` and not `<`.
        return result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    /// The capture groups of the first match.
    static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
