import Foundation

/// A name that is also typed as a command — `/scout`, `/skill:weekly-report` (user 2026-09-17): English, so nobody
/// switches the input method to call it — lower-case letters, digits, hyphens, a letter first. What the thing is for is
/// said in Chinese, in its description.
enum EnglishSlug {
    static func isValid(_ name: String) -> Bool {
        name.range(of: "^[a-z][a-z0-9]*(-[a-z0-9]+)*$", options: .regularExpression) != nil
    }

    /// What a try at a name comes to under the rule; empty when nothing of it is English.
    static func make(_ raw: String, limit: Int) -> String {
        let folded = String(raw.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let joined = folded.split(separator: "-").joined(separator: "-")
        return String(joined.drop { !$0.isLetter }.prefix(limit))
    }
}
