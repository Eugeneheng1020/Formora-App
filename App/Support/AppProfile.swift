import Foundation

/// Data-isolation profile. The default profile reads and writes the user's real data;
/// a named profile (e.g. `qa`) is fully separate and exists for tests and verification.
///
/// Select one with the launch argument `-FormoraProfile <name>` or the environment
/// variable `FORMORA_PROFILE`; the argument wins.
struct AppProfile: Equatable, Sendable {
    static let bundleIdentifier = "com.eugenecheng.formora"
    static let argumentKey = "-FormoraProfile"
    /// Pass as `-FormoraResetProfile YES`. Every launch argument must be a `-key value` pair:
    /// a bare token left over is taken by AppKit as a file to open, and SwiftUI then skips the default window.
    static let resetDefaultsKey = "FormoraResetProfile"
    static let environmentKey = "FORMORA_PROFILE"

    static let `default` = AppProfile(name: nil)
    static let current = resolve(arguments: ProcessInfo.processInfo.arguments,
                                 environment: ProcessInfo.processInfo.environment)

    enum ResetError: Error, Equatable {
        case defaultProfileIsProtected
    }

    /// `nil` means the default profile.
    let name: String?

    private init(name: String?) {
        self.name = name
    }

    /// Keeps lowercase ASCII letters, digits and hyphens; anything else is dropped.
    /// An empty result means the default profile.
    init(sanitizing raw: String) {
        let kept = raw.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
        let value = String(String.UnicodeScalarView(kept))
        self.name = value.isEmpty ? nil : value
    }

    static func resolve(arguments: [String], environment: [String: String]) -> AppProfile {
        if let index = arguments.firstIndex(of: argumentKey), index + 1 < arguments.count {
            return AppProfile(sanitizing: arguments[index + 1])
        }
        if let value = environment[environmentKey] {
            return AppProfile(sanitizing: value)
        }
        return .default
    }

    var isDefault: Bool { name == nil }

    var userDefaultsSuiteName: String? {
        name.map { "\(Self.bundleIdentifier).profile.\($0)" }
    }

    func makeUserDefaults() -> UserDefaults {
        guard let suite = userDefaultsSuiteName, let defaults = UserDefaults(suiteName: suite) else {
            return .standard
        }
        return defaults
    }

    var applicationSupportFolderName: String {
        name.map { "Formora-\($0)" } ?? "Formora"
    }

    /// Creates the folder if needed.
    func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func keychainServiceName(_ base: String) -> String {
        name.map { "\(base).\($0)" } ?? base
    }

    /// Wipes everything this profile stored. Refuses to touch the default profile.
    func reset() throws {
        guard let suite = userDefaultsSuiteName else { throw ResetError.defaultProfileIsProtected }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        let dir = try applicationSupportDirectory()
        try FileManager.default.removeItem(at: dir)
    }
}
