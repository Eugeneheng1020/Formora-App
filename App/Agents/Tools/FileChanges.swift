import CryptoKit
import Foundation

/// 10d: what a write or an edit changed, kept with its result — seen as a diff, undone from the file's history (Codex
/// `core/src/turn_diff_tracker.rs`: the net text diff of a turn; omp README §19: preview, then accept).
struct FileChange: Codable, Equatable, Sendable {
    var added: Int
    var removed: Int
    /// Unified, three lines of context, cut at `LineDiff.textLimit`; `nil` when the file was too long to compare.
    var diff: String?
    /// The file as it was, kept outside the conversation (its name in the history folder); `nil`: no 撤销.
    var snapshot: String?
    /// What was written: 撤销 only while the file is still that.
    var afterHash: String
    var wasNew: Bool
    var undone: Bool?

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 10d: the file as it was, kept for 撤销; the change a card waiting for 允许 shows; the way back.
enum FileHistory {
    /// After a write or an edit: what changed, and the old text kept in `history` — never inside the conversation.
    static func record(_ plan: FileTools.Plan, history: URL?) -> FileChange {
        let hash = FileChange.hash(plan.after)
        // It was there but wasn't text (an image, too large): nothing to compare, nothing to go back to.
        guard !plan.exists || plan.before != nil else {
            return FileChange(added: 0, removed: 0, diff: nil, snapshot: nil, afterHash: hash, wasNew: false)
        }
        let compared = LineDiff.compare(plan.before ?? "", plan.after)
        var snapshot: String?
        if plan.exists, let before = plan.before, let history {
            let name = UUID().uuidString + ".txt"
            try? FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            if (try? Data(before.utf8).write(to: history.appendingPathComponent(name), options: .atomic)) != nil { snapshot = name }
        }
        return FileChange(added: compared.added, removed: compared.removed, diff: compared.text, snapshot: snapshot, afterHash: hash,
                          wasNew: !plan.exists)
    }

    /// What a write or an edit waiting for 允许 would change, worked out without writing; `nil` when it can't be.
    static func preview(_ call: ToolCall, root: URL) -> String? {
        guard call.name == "write" || call.name == "edit", let args = ToolArguments.parse(call.arguments) else { return nil }
        let sandbox = ProjectSandbox(root: root, readRoots: [], writeRoots: [])
        guard let plan = try? (call.name == "write" ? FileTools.planWrite(args, sandbox) : FileTools.planEdit(args, sandbox)),
              !plan.exists || plan.before != nil else { return nil }
        return LineDiff.compare(plan.before ?? "", plan.after).text
    }

    static func canUndo(_ change: FileChange) -> Bool {
        change.undone != true && (change.wasNew || change.snapshot != nil)
    }

    /// Back to before the step — only while the file is still what it wrote, so nothing done since is lost. `nil`:
    /// done; otherwise why not.
    static func undo(_ change: FileChange, path: String, root: URL, history: URL?) -> String? {
        let url = root.appendingPathComponent(path)
        guard let current = try? String(contentsOf: url, encoding: .utf8), FileChange.hash(current) == change.afterHash else {
            return "这个文件后来又改过了，撤销会把后来的改动一起冲掉，所以没有撤销。"
        }
        if change.wasNew {
            do { try FileManager.default.removeItem(at: url) } catch { return "没能删掉这个新建的文件：\(error.localizedDescription)" }
            return nil
        }
        guard let name = change.snapshot, let history,
              let before = try? String(contentsOf: history.appendingPathComponent(name), encoding: .utf8) else {
            return "原来的内容没有留底，撤不回去。"
        }
        do { try Data(before.utf8).write(to: url, options: .atomic) } catch { return "没能写回原来的内容：\(error.localizedDescription)" }
        return nil
    }
}

/// A line-by-line comparison: Swift's own difference (Myers), shown the way `git diff` shows it.
enum LineDiff {
    /// Past this many lines on a side there is no comparing: counts and text are left out.
    static let lineLimit = 20_000
    static let textLimit = 20_000

    struct Result: Equatable {
        var added: Int
        var removed: Int
        var text: String?
    }

    static func compare(_ old: String, _ new: String, context: Int = 3) -> Result {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard before.count <= lineLimit, after.count <= lineLimit else { return Result(added: 0, removed: 0, text: nil) }
        let difference = after.difference(from: before)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        guard !removed.isEmpty || !inserted.isEmpty else { return Result(added: 0, removed: 0, text: nil) }
        // One line each: its mark, its text, and where it stands in the old and the new file.
        struct Line { let mark: Character; let text: String; let old: Int; let new: Int }
        var lines: [Line] = []
        var (i, j) = (0, 0)
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                lines.append(Line(mark: "-", text: before[i], old: i, new: j))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                lines.append(Line(mark: "+", text: after[j], old: i, new: j))
                j += 1
            } else {
                lines.append(Line(mark: " ", text: i < before.count ? before[i] : after[j], old: i, new: j))
                i += 1
                j += 1
            }
        }
        // Hunks: every change with `context` lines around it, close ones joined.
        let changed = lines.indices.filter { lines[$0].mark != " " }
        var hunks: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = hunks.last, range.lowerBound <= last.upperBound + 1 {
                hunks[hunks.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                hunks.append(range)
            }
        }
        var text = ""
        for hunk in hunks {
            let slice = lines[hunk]
            let oldCount = slice.filter { $0.mark != "+" }.count
            let newCount = slice.filter { $0.mark != "-" }.count
            let first = slice.first!
            text += "@@ -\(oldCount == 0 ? first.old : first.old + 1),\(oldCount) +\(newCount == 0 ? first.new : first.new + 1),\(newCount) @@\n"
            for line in slice { text += String(line.mark) + line.text + "\n" }
            if text.count > textLimit {
                text = String(text.prefix(textLimit)) + "\n…（改动太多，后面的没有列出）\n"
                break
            }
        }
        return Result(added: inserted.count, removed: removed.count, text: text)
    }
}
