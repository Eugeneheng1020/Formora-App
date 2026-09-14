import Foundation
import Sparkle

/// 自动更新 (user 2026-09-14): Sparkle reads `appcast.xml` from the Formora-App repository (through the jsDelivr mirror,
/// `SUFeedURL` in Info.plist) and installs the dmg from GitHub Releases. Checked once a day and from 设置 → 关于; the
/// update is EdDSA-signed by `scripts/publish-app.sh`, the public key is `SUPublicEDKey`. A named (QA) profile has no
/// updater unless `-FormoraUpdateFeed <url>` points it at a local appcast.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    private let feed: FeedDelegate

    /// `-FormoraUpdateFeed http://localhost:8766/appcast.xml`: a QA copy checks that feed instead of the real one.
    static let feedKey = "FormoraUpdateFeed"

    init(feedOverride: String? = nil) {
        feed = FeedDelegate(override: feedOverride)
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feed, userDriverDelegate: nil)
    }

    /// The menu item and the button: Sparkle shows what it found, or that this is the latest.
    func check() {
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    /// Sparkle asks which feed to read; the override answers, otherwise Info.plist's `SUFeedURL`.
    private final class FeedDelegate: NSObject, SPUUpdaterDelegate, Sendable {
        let override: String?

        init(override: String?) {
            self.override = override
        }

        func feedURLString(for updater: SPUUpdater) -> String? { override }
    }
}
