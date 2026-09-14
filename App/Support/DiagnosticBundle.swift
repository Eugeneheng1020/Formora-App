import Foundation

/// 诊断包 (user 2026-09-14: 「我没有服务器」— so the report is a zip the user sends themselves): what a bug report needs,
/// gathered on this Mac and nothing more. The user sees the list before anything is written.
struct DiagnosticBundle: Sendable {
    /// One thing the bundle would carry.
    struct Item: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case crash, log, conversation, about
        }

        let kind: Kind
        /// Where it comes from; `about` has none.
        let url: URL?
        let name: String

        var id: String { kind.rawValue + "/" + name }
    }

    static let crashReportDays = 7
    static let conversationHours: Double = 24

    /// Where macOS writes crash reports: `~/Library/Logs/DiagnosticReports`, its `Retired` subfolder too.
    static func crashReportsFolder(library: URL? = nil) -> URL {
        let base = library ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
    }

    /// Formora's crash reports of the last `crashReportDays`, newest first.
    static func crashReports(in folder: URL, now: Date = Date()) -> [URL] {
        let oldest = now.addingTimeInterval(-Double(crashReportDays) * 86_400)
        var found: [(URL, Date)] = []
        for dir in [folder, folder.appendingPathComponent("Retired", isDirectory: true)] {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("Formora-") || name.hasPrefix("Formora_"), ["ips", "crash", "diag"].contains(file.pathExtension) else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if date >= oldest { found.append((file, date)) }
            }
        }
        return found.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent > $1.0.lastPathComponent }.map(\.0)
    }

    /// The conversation files changed in the last `conversationHours`.
    static func recentConversations(in folder: URL?, now: Date = Date()) -> [URL] {
        guard let folder else { return [] }
        let oldest = now.addingTimeInterval(-conversationHours * 3_600)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { file in
            guard file.pathExtension == "json" else { return false }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return date >= oldest
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The list the user sees before exporting.
    static func items(crashReports: [URL], logs: [URL], conversations: [URL]) -> [Item] {
        crashReports.map { Item(kind: .crash, url: $0, name: $0.lastPathComponent) }
            + logs.map { Item(kind: .log, url: $0, name: $0.lastPathComponent) }
            + conversations.map { Item(kind: .conversation, url: $0, name: $0.lastPathComponent) }
            + [Item(kind: .about, url: nil, name: "about.txt")]
    }

    /// The one-line summary of the list (设置 → 关于).
    static func summary(_ items: [Item]) -> String {
        func count(_ kind: Item.Kind) -> Int { items.filter { $0.kind == kind }.count }
        return "\(count(.crash)) 份崩溃报告、\(count(.log)) 天日志、\(count(.conversation)) 条最近改动的对话，加上版本信息"
    }

    /// `about.txt`: versions and the shape of the setup — no key, no path inside the home folder beyond the profile's.
    static func about(version: String, build: String, profile: String?, providers: [String], agents: [(name: String, model: String)],
                      now: Date = Date()) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "Formora \(version) (\(build))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "profile: \(profile ?? "default")",
            "exported: \(ISO8601DateFormatter().string(from: now))",
            "providers with a key: \(providers.isEmpty ? "none" : providers.joined(separator: ", "))",
            "agents:",
        ]
        lines += agents.map { "  - \($0.name): \($0.model)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the bundle's folder — text files redacted line by line — and zips it next to it. Returns the zip.
    static func write(items: [Item], about: String, into parent: URL, name: String, redact: (String) -> String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in items {
            let target: URL
            switch item.kind {
            case .about:
                target = folder.appendingPathComponent("about.txt")
                try about.write(to: target, atomically: true, encoding: .utf8)
                continue
            case .crash: target = folder.appendingPathComponent("crashes", isDirectory: true).appendingPathComponent(item.name)
            case .log: target = folder.appendingPathComponent("logs", isDirectory: true).appendingPathComponent(item.name)
            case .conversation: target = folder.appendingPathComponent("conversations", isDirectory: true).appendingPathComponent(item.name)
            }
            guard let url = item.url else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                try redact(text).write(to: target, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.copyItem(at: url, to: target)
            }
        }
        let zip = parent.appendingPathComponent(name + ".zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw BundleProblem.zipFailed(ditto.terminationStatus) }
        try? FileManager.default.removeItem(at: folder)
        return zip
    }

    /// `Formora-诊断-20260914-2215`.
    static func bundleName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Formora-诊断-" + formatter.string(from: now)
    }

    enum BundleProblem: Error, LocalizedError {
        case zipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .zipFailed(let status): "打包失败（ditto 退出码 \(status)）"
            }
        }
    }
}

/// What the app hands 设置 → 关于: the folders the bundle reads and where the zip goes.
struct DiagnosticSources: Sendable {
    var logs: URL?
    var conversations: URL?
    var crashReports: URL = DiagnosticBundle.crashReportsFolder()
    /// The Desktop for the user's copy; a QA copy's own support folder, so tests never litter the Desktop.
    var exportFolder: URL?
    var profileName: String?
}
