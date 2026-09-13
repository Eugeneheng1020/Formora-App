import Foundation

/// The Developer ID build left the App Sandbox (7j, B1′): once, what a sandboxed build kept in its container comes to
/// where an unsandboxed app keeps it — this profile's Application Support folder and its preferences. Only the
/// profile being opened (a QA run never touches the user's data); nothing already in the new place is overwritten;
/// the container stays as it was. Tests never migrate.
enum SandboxMigration {
    @discardableResult
    static func run(_ profile: AppProfile, environment: [String: String] = ProcessInfo.processInfo.environment,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        guard environment["APP_SANDBOX_CONTAINER_ID"] == nil, environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil else { return [] }
        let container = home.appendingPathComponent("Library/Containers/\(AppProfile.bundleIdentifier)/Data/Library", isDirectory: true)
        return migrate(profile, from: container, to: home.appendingPathComponent("Library", isDirectory: true))
    }

    /// What came over: the folder's name and the preferences domain.
    static func migrate(_ profile: AppProfile, from old: URL, to library: URL, fileManager: FileManager = .default,
                        preferences: (String) -> UserDefaults? = defaults) -> [String] {
        var moved: [String] = []
        let folder = profile.applicationSupportFolderName
        let source = old.appendingPathComponent("Application Support/\(folder)", isDirectory: true)
        let destination = library.appendingPathComponent("Application Support/\(folder)", isDirectory: true)
        if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.copyItem(at: source, to: destination)) != nil { moved.append(folder) }
        }
        let domain = profile.userDefaultsSuiteName ?? AppProfile.bundleIdentifier
        let file = old.appendingPathComponent("Preferences/\(domain).plist")
        if let values = NSDictionary(contentsOf: file) as? [String: Any], !values.isEmpty, let target = preferences(domain),
           (target.persistentDomain(forName: domain) ?? [:]).isEmpty {
            target.setPersistentDomain(values, forName: domain)
            moved.append(domain)
        }
        return moved
    }

    /// The app's own domain is `standard`: `UserDefaults(suiteName:)` refuses the bundle identifier.
    static func defaults(_ domain: String) -> UserDefaults? {
        domain == AppProfile.bundleIdentifier ? .standard : UserDefaults(suiteName: domain)
    }
}
