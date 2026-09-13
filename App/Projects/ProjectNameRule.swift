import Foundation

/// A project's name is the name of the folder Formora creates for it, so it must be a valid,
/// visible macOS folder name.
enum ProjectNameRule {
    enum Problem: Equatable, Sendable {
        case empty
        case containsSeparator
        case reserved
        case startsWithDot
        case tooLong
    }

    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func problem(with raw: String) -> Problem? {
        let name = normalized(raw)
        if name.isEmpty { return .empty }
        if name.contains("/") || name.contains(":") { return .containsSeparator }
        if name == "." || name == ".." { return .reserved }
        if name.hasPrefix(".") { return .startsWithDot }
        if name.utf8.count > 255 { return .tooLong }
        return nil
    }

    static func message(for problem: Problem) -> String {
        switch problem {
        case .empty: "请填写项目名称"
        case .containsSeparator: "名称里不能有 / 或 :"
        case .reserved: "这个名称不能用作文件夹名"
        case .startsWithDot: "以 . 开头的文件夹在 Finder 里会被隐藏，换个名称"
        case .tooLong: "名称太长了，最多 255 个字节"
        }
    }
}
