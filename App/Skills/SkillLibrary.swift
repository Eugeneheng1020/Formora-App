import CryptoKit
import Foundation
import Observation

/// A `SKILL.md` as Claude writes it: a YAML header whose `name` and `description` (when to use it) are what
/// Formora reads, and a Markdown body written for the model; the folder may also hold `scripts/`, `references/`,
/// `assets/`… (copied whole on import). Other header fields (`allowed-tools`, `version`, `hooks`…) stay in the
/// file and are ignored — a Skill runs with the Agent's own permissions (todo #1, old app D65).
struct SkillDocument: Equatable, Sendable {
    var name: String
    var description: String
    var body: String

    /// `nil` without a `---` header, a name or a description. Both are read as one line (codex
    /// `sanitize_single_line`), so a `>` or `|` block reads as the sentence it is.
    static func parse(_ text: String) -> SkillDocument? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return nil }
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        let fields = header(String(rest[..<end.lowerBound]))
        guard let name = fields["name"].map(singleLine), !name.isEmpty,
              let description = fields["description"].map(singleLine), !description.isEmpty else { return nil }
        return SkillDocument(name: name, description: description, body: body)
    }

    /// The header's top-level `key: value` pairs. Lines indented under a key continue its value — a `|` / `>`
    /// block, a quoted or plain scalar folded over several lines — so a nested `metadata: description:` never
    /// stands in for the real one. Lenient about a colon inside a plain value (`Build for AWS: ECS`), as codex is.
    private static func header(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var continued: [String] = []
            while index < lines.count, lines[index].first?.isWhitespace ?? true {
                continued.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            if fields[key] == nil { fields[key] = scalar(value, continued) }
        }
        return fields
    }

    private static func scalar(_ value: String, _ continued: [String]) -> String {
        if value.first == "|" || value.first == ">" { return continued.joined(separator: "\n") }
        let joined = ([value] + continued).filter { !$0.isEmpty }.joined(separator: " ")
        if value.first == "\"" || value.first == "'" { return unquote(joined) }
        return joined.range(of: " #").map { String(joined[..<$0.lowerBound]) } ?? joined
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The file text; a round trip through `parse` gives back the same text.
    func rendered() -> String {
        "---\nname: \(Self.yaml(name))\ndescription: \(Self.yaml(description))\n---\n\(body)"
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    /// Plain when YAML would read it back unchanged; double-quoted otherwise.
    private static func yaml(_ raw: String) -> String {
        let value = raw.replacingOccurrences(of: "\n", with: " ")
        let special = value.contains(": ") || value.contains(" #") || value != value.trimmingCharacters(in: .whitespaces)
            || value.first.map { "[]{}&*!|>'\"%@`,-?#".contains($0) } == true
        guard special else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct Skill: Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case builtIn, imported, created
    }

    /// The folder name inside the Skills directory.
    let id: String
    var document: SkillDocument
    var source: Source
    /// Where an imported Skill was copied from.
    var importedFrom: String?

    var name: String { document.name }
}

enum SkillProblem: Error, Equatable {
    case noSkillFile, unreadable
    case duplicate(String)
    /// Enabled by this many Agents (spec §8.2, §8.7 rule 2).
    case inUse(Int)

    var message: String {
        switch self {
        case .noSkillFile: "这个文件夹里没有 SKILL.md"
        case .unreadable: "SKILL.md 开头需要 name 和 description 两个字段"
        case .duplicate(let name): "已经有一个叫「\(name)」的 Skill，没有重复导入"
        case .inUse(let count): "有 \(count) 个 Agent 启用了它，先在对应 Agent 的 Skills 标签里关掉"
        }
    }
}

/// The Skills directory (`<profile>/Skills/<id>/SKILL.md`): installed once, enabled per Agent (spec §8.2).
/// Built-ins are pre-installed rather than special: copied from the app bundle on first launch, then ordinary
/// entries — uninstallable, and an uninstalled one is not put back (old app 2026-09-09). Nobody edits a Skill in
/// the app (user 2026-09-11); its folder can be opened in Finder.
/// Imports are copied in, never referenced (old app D27), so uninstalling only removes our copy.
@MainActor
@Observable
final class SkillLibrary {
    struct Record: Codable, Equatable {
        var source: Skill.Source
        var importedFrom: String?
    }

    static let installedBuiltInsKey = "formora.skills.installedBuiltIns"
    static let recordsFileName = "skills.json"
    /// The confirmed built-ins in their display order (old app 2026-09-09; todo #2).
    nonisolated static let builtInOrder = ["requirement-brief", "implementation-plan", "debugging", "delivery-check",
                                           "skill-writing", "mcp-connect", "office-docx", "office-xlsx", "office-pptx", "office-pdf"]

    private(set) var skills: [Skill] = []
    /// How many Agents enable a Skill; wired to `AgentStore` at launch.
    @ObservationIgnored var usage: (String) -> Int = { _ in 0 }

    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let builtInFolder: URL?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var records: [String: Record] = [:]

    /// `folder == nil` keeps everything in memory (tests, previews).
    init(folder: URL?, builtInFolder: URL?, defaults: UserDefaults?) {
        self.folder = folder
        self.builtInFolder = builtInFolder
        self.defaults = defaults
        if let url = folder?.appendingPathComponent(Self.recordsFileName), let data = try? Data(contentsOf: url) {
            records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
        }
        reload()
    }

    func skill(_ id: String) -> Skill? { skills.first { $0.id == id } }

    /// Bundled Skills present in the app, in display order.
    var bundledIDs: [String] {
        guard let builtInFolder else { return [] }
        return Self.builtInOrder.filter {
            FileManager.default.fileExists(atPath: builtInFolder.appendingPathComponent("\($0)/SKILL.md").path)
        }
    }

    /// Installs built-ins not installed before, and brings an installed one up to date when its SKILL.md is still
    /// exactly a text some earlier Formora shipped (`versions.json`); a copy changed in Finder is left alone.
    func installBuiltIns() {
        guard let folder, let builtInFolder else { return }
        var installed = Set(defaults?.stringArray(forKey: Self.installedBuiltInsKey) ?? [])
        let shipped = Self.shippedVersions(in: builtInFolder)
        for id in bundledIDs {
            let source = builtInFolder.appendingPathComponent(id, isDirectory: true)
            let target = folder.appendingPathComponent(id, isDirectory: true)
            if !installed.contains(id) {
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: source, to: target)
                }
                records[id] = Record(source: .builtIn)
                installed.insert(id)
            } else if let current = Self.digest(ofSkillIn: target), current != Self.digest(ofSkillIn: source),
                      shipped[id]?.contains(current) == true {
                // Staged beside it (a dot folder `reload` skips), then swapped in, so a failed copy loses nothing.
                let staged = folder.appendingPathComponent(".\(id)-update", isDirectory: true)
                try? FileManager.default.removeItem(at: staged)
                if (try? FileManager.default.copyItem(at: source, to: staged)) != nil {
                    _ = try? FileManager.default.replaceItemAt(target, withItemAt: staged)
                }
            }
        }
        defaults?.set(installed.sorted(), forKey: Self.installedBuiltInsKey)
        saveRecords()
        reload()
    }

    /// `Skills/versions.json` in the bundle: for each built-in, the SHA-256 of every SKILL.md it has shipped with.
    static let versionsFileName = "versions.json"

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(ofSkillIn folder: URL) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent("SKILL.md"))).map(digest)
    }

    private static func shippedVersions(in builtInFolder: URL) -> [String: Set<String>] {
        guard let data = try? Data(contentsOf: builtInFolder.appendingPathComponent(versionsFileName)),
              let list = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return list.mapValues(Set.init)
    }

    func reload() {
        guard let folder else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let found: [Skill] = entries.compactMap { url in
            guard !url.lastPathComponent.hasPrefix("."), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let text = try? String(contentsOf: url.appendingPathComponent("SKILL.md"), encoding: .utf8),
                  let document = SkillDocument.parse(text) else { return nil }
            let id = url.lastPathComponent
            let record = records[id] ?? Record(source: Self.builtInOrder.contains(id) ? .builtIn : .imported)
            return Skill(id: id, document: document, source: record.source, importedFrom: record.importedFrom)
        }
        skills = Self.sorted(found)
    }

    /// Copies the folder in. Refuses a folder without SKILL.md, an unreadable header, and a name already taken.
    @discardableResult
    func importFolder(_ source: URL) throws -> Skill {
        let file = source.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: file.path) else { throw SkillProblem.noSkillFile }
        guard let text = try? String(contentsOf: file, encoding: .utf8), let document = SkillDocument.parse(text) else {
            throw SkillProblem.unreadable
        }
        if let existing = skills.first(where: { FileSearch.normalize($0.name) == FileSearch.normalize(document.name) }) {
            throw SkillProblem.duplicate(existing.name)
        }
        let id = uniqueID(for: source.lastPathComponent)
        records[id] = Record(source: .imported, importedFrom: source.path)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(id, isDirectory: true))
            saveRecords()
            reload()
        } else {
            skills = Self.sorted(skills + [Skill(id: id, document: document, source: .imported, importedFrom: source.path)])
        }
        return skill(id) ?? Skill(id: id, document: document, source: .imported, importedFrom: source.path)
    }

    /// A Skill an Agent writes (7f, F2): a new folder holding its SKILL.md. The name must be free.
    @discardableResult
    func create(name rawName: String, description rawDescription: String, body: String) throws -> Skill {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !name.isEmpty, !description.isEmpty else { throw SkillProblem.unreadable }
        if let existing = skills.first(where: { FileSearch.normalize($0.name) == FileSearch.normalize(name) }) {
            throw SkillProblem.duplicate(existing.name)
        }
        let document = SkillDocument(name: name, description: description, body: body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        let id = uniqueID(for: name)
        records[id] = Record(source: .created)
        if let folder {
            let target = folder.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(document.rendered().utf8).write(to: target.appendingPathComponent("SKILL.md"), options: .atomic)
            saveRecords()
            reload()
        } else {
            skills = Self.sorted(skills + [Skill(id: id, document: document, source: .created)])
        }
        return skill(id) ?? Skill(id: id, document: document, source: .created)
    }

    /// Where a Skill's files are; `nil` when the library lives in memory.
    func folder(of skill: Skill) -> URL? { folder?.appendingPathComponent(skill.id, isDirectory: true) }

    /// The library folder for 「在 Finder 中打开」, created if it isn't there yet; `nil` when the library lives in memory.
    func revealDirectory() -> URL? {
        guard let folder else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes our copy; refused while an Agent enables it. A built-in stays uninstalled.
    func uninstall(_ id: String) throws {
        let users = usage(id)
        guard users == 0 else { throw SkillProblem.inUse(users) }
        if let folder {
            let target = folder.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        records[id] = nil
        saveRecords()
        skills.removeAll { $0.id == id }
    }

    // MARK: Helpers

    private static func sorted(_ skills: [Skill]) -> [Skill] {
        skills.sorted { a, b in
            let ia = builtInOrder.firstIndex(of: a.id), ib = builtInOrder.firstIndex(of: b.id)
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// A folder name made of lowercase ASCII letters, digits and hyphens, unique in the directory.
    private func uniqueID(for raw: String) -> String {
        let scalars = raw.lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "-" }
        var base = String(scalars).split(separator: "-").joined(separator: "-")
        if base.isEmpty { base = "skill" }
        var candidate = base
        var counter = 2
        while skills.contains(where: { $0.id == candidate }) || records[candidate] != nil
                || folder.map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent(candidate).path) }) == true {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private func saveRecords() {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: folder.appendingPathComponent(Self.recordsFileName), options: .atomic)
        }
    }
}
