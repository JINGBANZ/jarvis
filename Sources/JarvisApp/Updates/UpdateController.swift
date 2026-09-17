import Foundation
import Sparkle

/// Checks are user-initiated only, so no autonomous path presents update UI: automatic checks stay
/// off here and in `Info.plist`. Callers must not offer the check while a session is live.
@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Nil without `SUFeedURL`, which `scripts/build-app.sh` strips so a local build never offers
    /// to replace itself with the release.
    init?() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = false
    }

    func checkForUpdates() {
        // ghost-mode-allowed: explicit menu action, offered only while no session is live
        controller.updater.checkForUpdates()
    }
}
