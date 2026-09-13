import AppKit
import SwiftUI

/// A mark after a provider's name (7i): 「订阅登录 · 非官方接入」.
struct ProviderTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FormoraFont.ui(10, weight: 600))
            .foregroundStyle(Palette.inkMuted.color)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(Capsule().fill(Palette.surfaceRaised2.color))
            .accessibilityIdentifier("models.tag")
    }
}

/// 「ChatGPT 订阅」's buttons (U1): sign in, or sign out.
struct ChatGPTButtons: View {
    let state: AppState

    private var providers: ProviderStore { state.providers }
    private var isSigningIn: Bool {
        switch providers.signIns[ChatGPTAuth.providerID] {
        case .waiting, .deviceCode: true
        default: false
        }
    }

    var body: some View {
        if providers.hasKey(ChatGPTAuth.providerID) {
            Button("退出登录") {
                do {
                    try providers.signOutChatGPT()
                    state.toasts.show("已退出 ChatGPT 登录", seconds: 2)
                } catch {
                    state.toasts.show("没有退出", note: (error as? ProviderFormProblem)?.message ?? error.localizedDescription, isError: true)
                }
            }
            .buttonStyle(FormoraButtonStyle())
            .accessibilityIdentifier("models.signOut.chatgpt")
        } else {
            Button("用 ChatGPT 登录") { Task { await providers.signInChatGPT() } }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .disabled(isSigningIn)
                .accessibilityIdentifier("models.signIn.chatgpt")
        }
    }
}

/// Under the row while signing in (U1): the browser is open; or the code to type; or why it failed.
struct ChatGPTSignInPanel: View {
    let state: AppState
    let progress: SignInProgress

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch progress {
            case .waiting:
                ProgressView().controlSize(.small)
                Text("在打开的浏览器里登录 ChatGPT，完成后会自动回到这里。")
                    .fixedSize(horizontal: false, vertical: true)
            case .deviceCode(let code):
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机的 1455 端口被占用（可能开着 Codex 的登录），改用登录码：在打开的网页里输入")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(code)
                        .font(FormoraFont.mono(16, weight: 700))
                        .foregroundStyle(Palette.ink.color)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("models.deviceCode")
                    HStack(spacing: 8) {
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        .buttonStyle(FormoraButtonStyle())
                        Button("再打开网页") { state.providers.openURL(ChatGPTAuth.deviceURL) }
                            .buttonStyle(FormoraButtonStyle())
                    }
                }
            case .failed(let reason):
                Text("没有登录成功：\(reason)")
                    .foregroundStyle(Palette.alert.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(isFailed ? "知道了" : "取消") { state.providers.cancelSignIn(ChatGPTAuth.providerID) }
                .buttonStyle(FormoraButtonStyle(kind: .ghost))
                .accessibilityIdentifier("models.signInCancel")
        }
        .font(FormoraFont.ui(11.5))
        .foregroundStyle(Palette.inkMuted.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.signInPanel")
    }

    private var isFailed: Bool {
        if case .failed = progress { return true }
        return false
    }
}
