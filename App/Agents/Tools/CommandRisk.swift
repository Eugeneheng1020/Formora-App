import Foundation

/// The seven kinds of command that always stop for the user, whatever the Agent's 权限模式 (7c, C3; old 4e): they
/// destroy what can't be got back or reach beyond the project. Each simple command of the line is checked — after
/// `;`, `&&`, `||`, `|`, a background `&` or `$(` — with `sudo`-like wrappers and `VAR=value` prefixes looked through.
/// The kinds follow codex's `is_dangerous_command` (forced rm, sudo) widened to the old app's seven.
enum CommandRisk {
    private static let rules: [(pattern: String, reason: String)] = [
        (#"^(sudo|su|doas)(\s|$)"#, "要用管理员权限运行"),
        (#"^rm\s+(\S+\s+)*?-(-force|-recursive|[A-Za-z]*[rRf][A-Za-z]*)(\s|$)"#, "会直接删除文件或整个文件夹，删了找不回来"),
        (#"^find\s.*\s-delete(\s|$)"#, "会批量删除找到的文件，删了找不回来"),
        (#"^git\s+(-C\s+\S+\s+)?(push\s+(\S+\s+)*?(-f|--force|--force-with-lease)(\s|$|=)|reset\s+(\S+\s+)*?--hard|clean\s+(\S+\s+)*?-[A-Za-z]*f|checkout\s+(\S+\s+)*?--\s+\.|restore\s+(\S+\s+)*?\.(\s|$)|branch\s+(\S+\s+)*?-D(\s|$))"#,
         "会丢掉没提交的改动，或者改写 git 历史"),
        (#"^(dd|mkfs(\.\w+)?|shutdown|reboot|halt|launchctl|csrutil|nvram|pmset)(\s|$)|^diskutil\s+(erase|partition|zero|secureErase|reformat)"#,
         "会改动磁盘或系统设置"),
        (#"^(chmod|chown)\s+(\S+\s+)*?(-[A-Za-z]*R[A-Za-z]*|777)(\s|$)"#, "会大范围改文件权限"),
        (#"^kill\s+(\S+\s+)*?-(9|KILL|SIGKILL)(\s|$)|^(killall|pkill)(\s|$)"#, "会强行结束别的程序"),
    ]

    /// Downloading and running in one line spans a pipe, so it is checked on the whole line.
    private static let downloadAndRun = (pattern: #"\b(curl|wget)\b[^\n;]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|ruby|perl|node)(\s|$)"#,
                                         reason: "会把网上下载的脚本直接运行")

    /// Why this command must ask first; `nil` for an ordinary one.
    static func reason(_ command: String) -> String? {
        if matches(downloadAndRun.pattern, command) { return downloadAndRun.reason }
        for part in simpleCommands(command) {
            if let rule = rules.first(where: { matches($0.pattern, part) }) { return rule.reason }
        }
        return nil
    }

    static func simpleCommands(_ command: String) -> [String] {
        let separated = command.replacingOccurrences(of: #"\|\||&&|;|\||&|\n|\$\(|`|\("#, with: "\n", options: .regularExpression)
        return separated.split(separator: "\n").map { stripWrappers(String($0).trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    /// `FOO=1 env nohup time xargs -0 rm -rf x` → `rm -rf x`; `sudo` itself is a rule, so it stays.
    private static func stripWrappers(_ command: String) -> String {
        var text = command
        let wrapper = #"^(\w+=\S*\s+|env(\s+-\S+)*\s+|nohup\s+|time\s+|exec\s+|command\s+|xargs(\s+-\S+)*\s+)"#
        while let range = text.range(of: wrapper, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
