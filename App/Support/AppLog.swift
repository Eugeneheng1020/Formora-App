import Foundation

/// The app's own log (user 2026-09-14: a diagnostic bundle needs one — until now nothing was written anywhere):
/// one file a day under `~/Library/Logs/Formora` (a named profile: `Formora-<name>`), seven days kept. Lines are
/// `time level [category] message`; keys and credential-shaped strings are redacted before they land, and nothing
/// logged carries a request body or a reply — counts, names, statuses and errors only.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    enum Level: String, Sendable {
        case info = "INFO", warn = "WARN", error = "ERROR"
    }

    static let keepDays = 7
    static let fileExtension = "log"

    private let queue = DispatchQueue(label: "com.eugenecheng.formora.log", qos: .utility)
    private let lock = NSLock()
    private var folderURL: URL?
    private var handle: FileHandle?
    private var openDay = ""
    private var redact: @Sendable (String) -> String = { $0 }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Where a profile's log lives: `~/Library/Logs/Formora`, or `Formora-<name>` for a named (QA) profile.
    static func folder(profileName: String?, library: URL? = nil) -> URL {
        let base = library ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return base.appendingPathComponent("Logs/" + (profileName.map { "Formora-\($0)" } ?? "Formora"), isDirectory: true)
    }

    /// Opens the folder (created when missing), drops files older than `keepDays`, and records the app's start.
    func start(folder: URL, redact: @escaping @Sendable (String) -> String, version: String, now: Date = Date()) {
        lock.withLock {
            folderURL = folder
            self.redact = redact
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.prune(folder, now: now)
        write(.info, "app", "启动 Formora \(version)", now: now)
    }

    /// The log's folder, once started.
    var folder: URL? { lock.withLock { folderURL } }

    func write(_ level: Level, _ category: String, _ message: String, now: Date = Date()) {
        let line = "\(Self.timeFormatter.string(from: now)) \(level.rawValue) [\(category)] \(message.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
        queue.async { [self] in
            guard let folder = lock.withLock({ folderURL }) else { return }
            let safe = lock.withLock { redact }(line)
            let day = Self.dayFormatter.string(from: now)
            if day != openDay || handle == nil {
                try? handle?.close()
                let url = folder.appendingPathComponent("\(day).\(Self.fileExtension)")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
                openDay = day
            }
            try? handle?.write(contentsOf: Data(safe.utf8))
        }
    }

    static func info(_ category: String, _ message: String) { shared.write(.info, category, message) }
    static func warn(_ category: String, _ message: String) { shared.write(.warn, category, message) }
    static func error(_ category: String, _ message: String) { shared.write(.error, category, message) }

    /// Everything written so far is on disk (tests, and before the bundle copies the files).
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// The day files, newest first.
    func files() -> [URL] {
        guard let folder else { return [] }
        return Self.files(in: folder)
    }

    static func files(in folder: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == fileExtension }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Files older than `keepDays` go; the name is the day, so no attribute is read.
    static func prune(_ folder: URL, now: Date) {
        let oldest = dayFormatter.string(from: now.addingTimeInterval(-Double(keepDays) * 86_400))
        for file in files(in: folder) where file.deletingPathExtension().lastPathComponent < oldest {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
