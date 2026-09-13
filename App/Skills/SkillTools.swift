import Foundation

/// Skills in use (7f, F1–F2): the prompt lists only each enabled Skill's name and description; `skill` loads the full
/// instructions and the folder when the task calls for it (Claude's three loading levels), `skill_create` writes a
/// new one (the built-in 「写 Skill」 relies on it).
enum SkillTools {
    static let load = ToolSpec(
        name: "skill",
        description: "Load one of your Skills — its full instructions and where its files are — before doing the task it describes. Relative paths in the instructions are inside the Skill's folder: read its references with read (by absolute path) and run its scripts with bash.",
        parameters: #"{"type":"object","properties":{"name":{"type":"string","description":"The Skill's name as listed"}},"required":["name"]}"#,
        tier: .read)

    static let create = ToolSpec(
        name: "skill_create",
        description: "Create a new Skill in the user's Skills library, for a way of working the user wants reused. name: short; description: what it does and when to use it, in the words users say; instructions: the SKILL.md body in Markdown. Returns the new Skill's folder — put references/ or scripts/ into it with write. It is enabled for you at once; the user can turn it off in your Skills tab.",
        parameters: #"{"type":"object","properties":{"name":{"type":"string"},"description":{"type":"string"},"instructions":{"type":"string"}},"required":["name","description","instructions"]}"#,
        tier: .write)

    /// By its listed name, or its folder name; case and width don't matter.
    static func find(_ raw: String, in skills: [Skill]) -> Skill? {
        let name = FileSearch.normalize(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !name.isEmpty else { return nil }
        return skills.first { FileSearch.normalize($0.name) == name || $0.id == raw }
    }

    /// What `skill` returns: the instructions, the folder, and the files in it besides SKILL.md.
    static func loaded(_ skill: Skill, folder: URL?) -> String {
        var text = "# \(skill.name)\n\n\(skill.document.body.trimmingCharacters(in: .whitespacesAndNewlines))"
        guard let folder else { return text }
        text += "\n\n---\n这个 Skill 的文件夹：\(folder.path)\n正文里的相对路径都在这个文件夹里：参考资料用 read 读（写完整路径），脚本用 bash 运行。"
        // Both sides with their symlinks resolved: the walk reports /private/var/… for a folder named /var/….
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let files = FileTools.files(under: folder).map { url -> String in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
        }
        .filter { $0 != "SKILL.md" }.sorted()
        if !files.isEmpty {
            text += "\n里面的文件：\n" + files.prefix(40).map { "- \($0)" }.joined(separator: "\n")
            if files.count > 40 { text += "\n- ……还有 \(files.count - 40) 个" }
        }
        return text
    }
}
