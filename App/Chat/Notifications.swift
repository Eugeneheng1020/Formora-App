import AppKit
import Observation
import UserNotifications

/// 设置 → 通知 (mockup `NOTIFY_PREFS`): three switches, on by default, kept in the profile's defaults.
@MainActor
@Observable
final class NotificationSettings {
    enum Permission: Equatable {
        case unknown, allowed, denied
    }

    private(set) var desktop: Bool
    private(set) var sound: Bool
    private(set) var badge: Bool
    /// What macOS allows Formora; `denied` is explained under the switch.
    var permission: Permission = .unknown

    @ObservationIgnored private let defaults: UserDefaults?

    static let desktopKey = "notify.desktop"
    static let soundKey = "notify.sound"
    static let badgeKey = "notify.badge"

    /// `defaults == nil` keeps them in memory (tests).
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        desktop = defaults?.object(forKey: Self.desktopKey) as? Bool ?? true
        sound = defaults?.object(forKey: Self.soundKey) as? Bool ?? true
        badge = defaults?.object(forKey: Self.badgeKey) as? Bool ?? true
    }

    func setDesktop(_ on: Bool) {
        desktop = on
        defaults?.set(on, forKey: Self.desktopKey)
    }

    func setSound(_ on: Bool) {
        sound = on
        defaults?.set(on, forKey: Self.soundKey)
    }

    func setBadge(_ on: Bool) {
        badge = on
        defaults?.set(on, forKey: Self.badgeKey)
    }
}

/// macOS notifications for replies that land while Formora is in the background. Clicking one opens the
/// conversation. Permission is asked the first time it is needed, or when 桌面通知 is switched on.
@MainActor
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let settings: NotificationSettings
    var onOpen: (UUID) -> Void = { _ in }

    init(settings: NotificationSettings) {
        self.settings = settings
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshPermission() }
    }

    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        settings.permission = switch status {
        case .authorized, .provisional: .allowed
        case .denied: .denied
        default: .unknown
        }
    }

    @discardableResult
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
        await refreshPermission()
        return granted
    }

    /// The reply's first line as the body; our own sound plays separately (提示音 is its own switch).
    func post(title: String, body: String, conversationID: UUID) {
        Task {
            if settings.permission == .unknown { await requestPermission() }
            guard settings.permission == .allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["conversation": conversationID.uuidString]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["conversation"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            onOpen(id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
