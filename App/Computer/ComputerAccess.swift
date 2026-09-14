import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// What this build can do (7j, B1): computer use exists only in the Developer ID build — the App Store doesn't allow
/// the permissions it needs.
enum ComputerBuild {
    #if FORMORA_DEVELOPER_ID
    static let isAvailable = true
    #else
    static let isAvailable = false
    #endif
}

/// The three macOS permissions computer use needs (7j, B2).
enum ComputerPermission: String, CaseIterable, Identifiable, Sendable {
    case screen, accessibility, automation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "屏幕录制"
        case .accessibility: "辅助功能"
        case .automation: "自动化"
        }
    }

    var purpose: String {
        switch self {
        case .screen: "截屏，看屏幕和窗口上有什么。"
        case .accessibility: "读窗口里的按钮和文字，点按、打字、按快捷键。"
        case .automation: "用脚本控制其他应用；每个应用第一次会单独问，这里查的是访达。"
        }
    }

    /// Its pane in 系统设置 → 隐私与安全性.
    var settingsURL: URL? {
        let pane = switch self {
        case .screen: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

enum PermissionState: Equatable, Sendable {
    case granted, denied, notAsked
    /// It couldn't be asked: why.
    case unknown(String)

    var label: String {
        switch self {
        case .granted: "已授权"
        case .denied: "未授权"
        case .notAsked: "还没问过"
        case .unknown(let reason): reason
        }
    }
}

/// How the permissions are read and asked for: the system's, or a test's stand-in.
struct PermissionProbe: Sendable {
    var check: @Sendable (ComputerPermission) -> PermissionState
    var request: @Sendable (ComputerPermission) -> PermissionState

    static let system = PermissionProbe(check: { SystemPermissions.state($0, asking: false) },
                                        request: { SystemPermissions.state($0, asking: true) })
}

/// macOS's own answers (the old app's phase 0 probe): screen recording and accessibility by their preflight calls,
/// automation by asking whether Finder may be scripted.
enum SystemPermissions {
    static func state(_ permission: ComputerPermission, asking: Bool) -> PermissionState {
        switch permission {
        case .screen:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return asking && CGRequestScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            if AXIsProcessTrusted() { return .granted }
            guard asking else { return .denied }
            // The prompt option's key spelled out: the imported constant is a mutable global under Swift 6.
            return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) ? .granted : .denied
        case .automation:
            let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            return withExtendedLifetime(finder) {
                guard let target = finder.aeDesc else { return .unknown("查不到") }
                let status = AEDeterminePermissionToAutomateTarget(target, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking)
                switch Int(status) {
                case 0: return .granted
                case errAEEventNotPermitted: return .denied
                case errAEEventWouldRequireUserConsent: return .notAsked
                case procNotFound: return .unknown("访达没在运行")
                default: return .unknown("查不到（\(status)）")
                }
            }
        }
    }
}

/// The three permissions as last read (7j, B2): read again when 电脑操作 opens and whenever Formora comes back.
@MainActor
@Observable
final class ComputerAccess {
    private(set) var states: [ComputerPermission: PermissionState] = [:]
    @ObservationIgnored private let probe: PermissionProbe

    init(probe: PermissionProbe = .system) {
        self.probe = probe
    }

    func state(_ permission: ComputerPermission) -> PermissionState { states[permission] ?? .notAsked }

    /// What still stands in the way; not yet read counts as missing.
    var missing: [ComputerPermission] { ComputerPermission.allCases.filter { state($0) != .granted } }

    /// Off the main thread: asking about Finder can take a moment.
    func refresh() async {
        let probe = probe
        states = await Task.detached {
            Dictionary(uniqueKeysWithValues: ComputerPermission.allCases.map { ($0, probe.check($0)) })
        }.value
    }

    /// Screen recording and accessibility show macOS's prompt and return at once; automation waits for the
    /// answer, so it is asked off the main thread.
    func request(_ permission: ComputerPermission) async {
        let probe = probe
        if permission == .automation {
            states[permission] = await Task.detached { probe.request(permission) }.value
        } else {
            states[permission] = probe.request(permission)
        }
    }

    func openSettings(_ permission: ComputerPermission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}
