import Darwin
import Foundation

enum PathText {
    /// The user's real home folder. `NSHomeDirectory()` is the sandbox container, which users never see.
    static let realHome: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    /// `/Users/me/Desktop/app` → `~/Desktop/app`.
    static func abbreviate(_ path: String, home: String = realHome) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
