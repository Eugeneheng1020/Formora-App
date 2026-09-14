import AppKit
import SwiftUI

/// 设置 → 关于 (2026-09-14): the version, updates (Sparkle from GitHub Releases), and the diagnostic bundle — the zip
/// the user sends when something went wrong, since Formora has no server to send it to.
struct AboutSection: View {
    let state: AppState

    @State private var items: [DiagnosticBundle.Item] = []
    @State private var showsItems = false
    @State private var exporting = false
    @State private var checksAutomatically = true

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .about, note: "版本、更新和问题反馈。") { EmptyView() }
            SettingRow(label: "版本",
                       description: "Formora \(version)（构建 \(build)），每天自动检查一次新版本。") {
                if let updater = state.updater {
                    HStack(spacing: 12) {
                        FormoraSwitch(isOn: Binding(get: { checksAutomatically }, set: { on in
                            checksAutomatically = on
                            updater.checksAutomatically = on
                        }), label: "自动检查更新", identifier: "about.autoUpdate")
                        Button("检查更新") { updater.check() }
                            .buttonStyle(FormoraButtonStyle())
                            .disabled(!updater.canCheck)
                            .accessibilityIdentifier("about.checkUpdates")
                    }
                    .onAppear { checksAutomatically = updater.checksAutomatically }
                } else {
                    Text("这个副本不检查更新")
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkFaint.color)
                        .accessibilityIdentifier("about.noUpdater")
                }
            }
            SettingRow(label: "诊断包",
                       description: "崩溃报告、7 天日志、最近一天的对话和版本信息打成 zip 放到"
                           + (state.diagnosticSources.profileName == nil ? "桌面" : "这个副本的文件夹") + "，密钥已遮蔽、不会自动发送。\n里面现在有："
                           + DiagnosticBundle.summary(items) + "。") {
                VStack(alignment: .trailing, spacing: 8) {
                    Button(exporting ? "正在打包…" : "导出诊断包…", action: export)
                        .buttonStyle(FormoraButtonStyle(kind: .primary))
                        .disabled(exporting)
                        .accessibilityIdentifier("about.exportDiagnostics")
                    HStack(spacing: 8) {
                        Button(showsItems ? "收起清单" : "看清单") { showsItems.toggle() }
                            .buttonStyle(FormoraButtonStyle(kind: .ghost))
                            .accessibilityIdentifier("about.diagnosticsList")
                        Button("打开日志文件夹", action: openLogs)
                            .buttonStyle(FormoraButtonStyle(kind: .ghost))
                            .accessibilityIdentifier("about.openLogs")
                    }
                }
            }
            if showsItems {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        Text(Self.folder(item.kind) + item.name)
                            .font(FormoraFont.mono(11))
                            .foregroundStyle(Palette.inkMuted.color)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
                .padding(.vertical, 12)
                .accessibilityIdentifier("about.diagnosticsItems")
            }
            SettingRow(label: "反馈", description: "到 GitHub Issues 提问题，附上诊断包最省事。", showsRule: false) {
                Button("去 GitHub 反馈") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Eugeneheng1020/Formora-App/issues")!)
                }
                .buttonStyle(FormoraButtonStyle(kind: .ghost))
                .accessibilityIdentifier("about.feedback")
            }
        }
        .onAppear(perform: gather)
    }

    private static func folder(_ kind: DiagnosticBundle.Item.Kind) -> String {
        switch kind {
        case .crash: "crashes/"
        case .log: "logs/"
        case .conversation: "conversations/"
        case .about: ""
        }
    }

    private func gather() {
        AppLog.shared.flush()
        let sources = state.diagnosticSources
        items = DiagnosticBundle.items(crashReports: DiagnosticBundle.crashReports(in: sources.crashReports),
                                       logs: sources.logs.map(AppLog.files(in:)) ?? [],
                                       conversations: DiagnosticBundle.recentConversations(in: sources.conversations))
    }

    private func export() {
        gather()
        guard let folder = state.diagnosticSources.exportFolder else {
            state.toasts.show("没有可以放诊断包的地方", isError: true)
            return
        }
        exporting = true
        let about = DiagnosticBundle.about(
            version: version, build: build, profile: state.diagnosticSources.profileName,
            providers: state.providers.entries.filter { state.providers.hasKey($0.id) }.map(\.id),
            agents: state.agents.agents.map { ($0.displayName, "\($0.providerID ?? "?")/\($0.modelID)") })
        let items = items
        let name = DiagnosticBundle.bundleName()
        let shield = SecretShield.shared
        Task.detached {
            let outcome = Result { try DiagnosticBundle.write(items: items, about: about, into: folder, name: name, redact: shield.redact) }
            await MainActor.run {
                exporting = false
                switch outcome {
                case .success(let zip):
                    AppLog.info("about", "导出诊断包 \(zip.lastPathComponent)")
                    state.toasts.show("诊断包已导出", note: zip.lastPathComponent)
                    // The user's copy shows it in the Finder; a QA copy keeps the screen to itself.
                    if state.diagnosticSources.profileName == nil { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
                case .failure(let error):
                    state.toasts.show("诊断包没有导出", note: error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func openLogs() {
        guard let logs = state.diagnosticSources.logs else { return }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logs)
    }
}
