import Foundation
import Sparkle

/// Sparkle adapter for the menu bar's "Check for Updates…" item.
///
/// Checks are user-initiated only: `SUEnableAutomaticChecks` is false in `Info.plist` (which also
/// suppresses Sparkle's first-launch "check automatically?" prompt) and scheduled checks stay off
/// here, so no autonomous path can present update UI. The caller is responsible for the other half
/// of that contract — not offering the check while a session is live (see `MenuBarController`).
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController

    /// Whether Sparkle is ready to run a check right now — false while one is already in flight.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Fails when the bundle carries no `SUFeedURL`, which is exactly the development bundle:
    /// `scripts/build-app.sh` strips the key so a self-signed local build never offers to replace
    /// itself with the Developer ID release. Callers omit the menu item entirely when this is nil.
    init?() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false
    }

    /// Runs an explicit check, presenting Sparkle's standard UI for the result either way.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
