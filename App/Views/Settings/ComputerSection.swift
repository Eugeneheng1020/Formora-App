import AppKit
import SwiftUI

/// 设置 → 电脑操作 (7j, B2, old D40): the three macOS permissions, each with its state, 请求授权 and 打开系统设置,
/// read again whenever Formora comes back to the front. A build without computer use says so instead.
struct ComputerSection: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .computer,
                                note: "Agent 和 Bob 操作电脑需要的三个系统权限。") { EmptyView() }
            if ComputerBuild.isAvailable {
                ForEach(ComputerPermission.allCases) { permission in
                    PermissionRow(permission: permission, access: state.computer)
                }
                Text("授权屏幕录制后 macOS 会重启 Formora；哪个 Agent 能操作电脑在它的「模型与权限」里开，Bob 的在「Bob」页开。")
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkFaint.color)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("这个版本没有电脑操作").font(FormoraFont.ui(13, weight: 600)).foregroundStyle(Palette.ink.color)
                    Text("App Store 版没有电脑操作，官网下载的版本才有。")
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
                .accessibilityIdentifier("computer.unavailable")
            }
        }
        .task { if ComputerBuild.isAvailable { await state.computer.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard ComputerBuild.isAvailable else { return }
            Task { await state.computer.refresh() }
        }
    }
}

private struct PermissionRow: View {
    let permission: ComputerPermission
    let access: ComputerAccess

    private var current: PermissionState { access.state(permission) }

    var body: some View {
        SettingRow(label: permission.title, description: permission.purpose) {
            HStack(spacing: 10) {
                PermissionStatus(state: current)
                    .accessibilityIdentifier("computer.state.\(permission.rawValue)")
                if current != .granted {
                    Button("请求授权") { Task { await access.request(permission) } }
                        .buttonStyle(FormoraButtonStyle())
                        .accessibilityIdentifier("computer.request.\(permission.rawValue)")
                }
                Button("打开系统设置") { access.openSettings(permission) }
                    .buttonStyle(FormoraButtonStyle(kind: .ghost))
                    .accessibilityIdentifier("computer.settings.\(permission.rawValue)")
            }
        }
        .accessibilityIdentifier("computer.row.\(permission.rawValue)")
    }
}

/// A dot and a word: granted in green, refused in the alert colour, the rest muted.
struct PermissionStatus: View {
    let state: PermissionState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(state.label).font(FormoraFont.ui(11)).foregroundStyle(color)
        }
        .fixedSize()
    }

    private var color: Color {
        switch state {
        case .granted: Palette.success.color
        case .denied: Palette.alert.color
        case .notAsked, .unknown: Palette.inkMuted.color
        }
    }
}
