import AppKit
import SwiftUI

/// 设置 → 通知 (mockup `NOTIFY_PREFS`): three switches. When macOS has Formora's notifications turned off, the
/// row says so and offers the way there.
struct NotificationsSection: View {
    let state: AppState

    var body: some View {
        let settings = state.notifications
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .notifications, note: "Agent 回复时怎么提醒你；系统权限在 macOS 通知设置里。") { EmptyView() }
            SettingRow(label: "桌面通知", description: "Formora 不在前台时，Agent 回复会弹出系统通知。",
                       showsRule: !(settings.desktop && settings.permission == .denied)) {
                FormoraSwitch(isOn: Binding(get: { settings.desktop }, set: { on in
                    settings.setDesktop(on)
                    if on { state.checkNotificationPermission(true) }
                }), label: "桌面通知", identifier: "notify.desktop")
            }
            if settings.desktop, settings.permission == .denied {
                HStack(spacing: 12) {
                    Text("macOS 里 Formora 的通知是关着的，打开后才会弹出。")
                        .font(FormoraFont.ui(11.5))
                        .foregroundStyle(Palette.alert.color)
                    Spacer(minLength: 0)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(FormoraButtonStyle())
                }
                .padding(.bottom, 13)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                .accessibilityIdentifier("notify.denied")
            }
            SettingRow(label: "消息提示音", description: "没在看的对话有新回复时响一声。") {
                FormoraSwitch(isOn: Binding(get: { settings.sound }, set: { settings.setSound($0) }),
                              label: "消息提示音", identifier: "notify.sound")
            }
            SettingRow(label: "未读角标", description: "图标栏「消息」上显示未读数量。") {
                FormoraSwitch(isOn: Binding(get: { settings.badge }, set: { settings.setBadge($0) }),
                              label: "未读角标", identifier: "notify.badge")
            }
        }
        .task { state.checkNotificationPermission(false) }
    }
}
