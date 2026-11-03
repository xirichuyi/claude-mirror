#if canImport(SwiftUI)
import AppKit
import Sparkle

/// Sparkle owns download, signature verification, replacement and relaunch.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private weak var model: AppModel?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    init(model: AppModel) { self.model = model }

    func start() {
        do {
            try controller.updater.start()
            // Check on every launch, even when the scheduled daily check is not due.
            check(manual: false)
        } catch { model?.show(error.localizedDescription) }
    }

    func check(manual: Bool) {
        if !controller.updater.sessionInProgress { model?.checkingForUpdates = true }
        if manual { controller.checkForUpdates(nil) }
        else { controller.updater.checkForUpdatesInBackground() }
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        model?.checkingForUpdates = false
        model?.availableUpdate = nil
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        model?.availableUpdate = item.displayVersionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        model?.checkingForUpdates = false
    }
}
#endif
