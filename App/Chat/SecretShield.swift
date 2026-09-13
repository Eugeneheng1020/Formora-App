import CryptoKit
import Foundation

/// 10a: secrets never reach a model or the memory (omp `docs/secrets.md`, Codex `secrets/src/sanitizer.rs`). Everything a
/// model is sent passes `ChatWire.request`, which hides them behind placeholders; what comes back has them restored, so an
/// Agent that has to use a key still can. The memory gets a one-way mark instead.
final class SecretShield: @unchecked Sendable {
    static let shared = SecretShield()

    /// Every placeholder starts with this.
    static let marker = "$$SECRET_"
    static let memoryMark = "[密钥已遮挡]"
    static let minimumLength = 8
    /// Told to the model when a request hid something (Y4).
    static let note = "（对话里形如 $$SECRET_…$$ 的是被遮住的密钥：需要用它时照原样写这个占位符，执行时会换回真值；不要猜、也不要复述它的内容。）"

    /// Credential-shaped strings (Y2). With a capture group, the group is the secret (a `Bearer` token without its word).
    static let credentialPatterns: [NSRegularExpression] = [
        #"sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}"#,
        #"gh[pousr]_[A-Za-z0-9]{36,}"#,
        #"github_pat_[A-Za-z0-9_]{22,}"#,
        #"glpat-[A-Za-z0-9_-]{20,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"xox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"AIza[0-9A-Za-z_-]{35}"#,
        #"(?i:\bBearer)[ \t]+([A-Za-z0-9._~+/-]{20,}=*)"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"#,
        // The tokens the MCP catalog asks for, and a few more a user may paste (D93: Figma's figd_ went out as it was).
        #"figd_[A-Za-z0-9_-]{30,}"#,
        #"lin_api_[A-Za-z0-9]{30,}"#,
        #"sntry[su]_[A-Za-z0-9+/=_-]{30,}"#,
        #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#,
        #"\bfc-[A-Za-z0-9]{24,}"#,
        #"ntn_[A-Za-z0-9]{30,}"#,
        #"sbp_[A-Za-z0-9]{30,}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// In what the user types (D93): a long run of letters and digits right after 令牌 / 密钥 / key / token is a key,
    /// whatever its format. Only there — in code a model reads, `token: …` is too ordinary to hide (Y3).
    static let typedPattern = try! NSRegularExpression(
        pattern: #"(?:令牌|密钥|秘钥|(?i:(?<![A-Za-z])(?:api[ _-]?key|access[ _-]?key|key|token|secret)(?![A-Za-z_])))[^\S\n]*(?:[:：=]|是|为|(?i:is))?[^\S\n]*["'“「]?((?=[A-Za-z0-9._~+/=-]*[0-9])(?=[A-Za-z0-9._~+/=-]*[A-Za-z])[A-Za-z0-9._~+/=-]{20,})"#)

    /// `api_key = …`, `password: …` — for the memory only (Y3): in code it is too ordinary to hide from the model. The
    /// value is what a secret is made of and ends where a word would: `generate()` is a call, not a password.
    static let assignmentPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(api[_-]?key|access[_-]?key|token|secret|password|passwd)\b(\s*[:=]\s*)(["']?)([A-Za-z0-9_\-.~+/=!@#$%^&*]{8,})(?=["'\s,;，。；、）)]|$)"#)

    static let placeholderPattern = try! NSRegularExpression(pattern: #"\$\$SECRET_[0-9A-F]{8}\$\$"#)

    private let lock = NSLock()
    private var known: Set<String> = []
    /// Placeholder → value, for what comes back.
    private var values: [String: String] = [:]

    init() {}

    /// A key Formora keeps (a provider's, an MCP server's), registered as it is read (Y2).
    func register(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= Self.minimumLength else { return }
        lock.withLock { _ = known.insert(value) }
    }

    /// The same value, the same placeholder: a conversation reads the same every time (Y1).
    static func placeholder(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return marker + digest.prefix(4).map { String(format: "%02X", $0) }.joined() + "$$"
    }

    /// Before a model sees it: known keys and credential-shaped strings as placeholders. `typedByUser`: also what the
    /// user gives as a key (D93) — kept as a known key from then on, so it stays hidden wherever it shows up.
    func hide(_ text: String, typedByUser: Bool = false) -> (text: String, hidden: Bool) {
        var found = secrets(in: text, patterns: Self.credentialPatterns)
        if typedByUser {
            let typed = secrets(in: text, patterns: [Self.typedPattern])
            for value in typed { register(value) }
            found = Array(Set(found + typed)).sorted { $0.count > $1.count }
        }
        guard !found.isEmpty else { return (text, false) }
        var hidden = text
        for value in found {
            let placeholder = Self.placeholder(for: value)
            lock.withLock { values[placeholder] = value }
            hidden = hidden.replacingOccurrences(of: value, with: placeholder)
        }
        return (hidden, hidden != text)
    }

    /// What a model wrote, with its placeholders swapped back; one it never saw stays as it is.
    func restore(_ text: String) -> String {
        guard text.contains(Self.marker) else { return text }
        let table = lock.withLock { values }
        var restored = text
        let range = NSRange(text.startIndex..., in: text)
        for match in Self.placeholderPattern.matches(in: text, range: range).reversed() {
            guard let found = Range(match.range, in: text), let value = table[String(text[found])],
                  let target = Range(match.range, in: restored) else { continue }
            restored.replaceSubrange(target, with: value)
        }
        return restored
    }

    func restore(_ calls: [ToolCall]) -> [ToolCall] {
        calls.map { call in
            var call = call
            call.arguments = restore(call.arguments)
            return call
        }
    }

    /// For the memory (Y5): keys, credential-shaped strings, assignments and placeholders — one way.
    func redact(_ text: String) -> String {
        var redacted = text
        for value in secrets(in: text, patterns: Self.credentialPatterns + [Self.typedPattern]) {
            redacted = redacted.replacingOccurrences(of: value, with: Self.memoryMark)
        }
        let range = NSRange(redacted.startIndex..., in: redacted)
        redacted = Self.assignmentPattern.stringByReplacingMatches(in: redacted, range: range, withTemplate: "$1$2$3\(Self.memoryMark)")
        let all = NSRange(redacted.startIndex..., in: redacted)
        return Self.placeholderPattern.stringByReplacingMatches(in: redacted, range: all, withTemplate: Self.memoryMark)
    }

    /// The secrets in `text`, longest first — a key inside a longer match goes with it.
    private func secrets(in text: String, patterns: [NSRegularExpression]) -> [String] {
        guard text.count >= Self.minimumLength else { return [] }
        var found = lock.withLock { known.filter { text.contains($0) } }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            for match in pattern.matches(in: text, range: range) {
                let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                if let value = Range(group, in: text).map({ String(text[$0]) }), value.count >= Self.minimumLength { found.insert(value) }
            }
        }
        return found.sorted { $0.count > $1.count }
    }
}
