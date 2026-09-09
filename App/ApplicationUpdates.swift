import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class ApplicationUpdates: NSObject, @MainActor SPUStandardUserDriverDelegate, NSMenuItemValidation {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var menuItems: [NSMenuItem] = []
    @ObservationIgnored var onVisibilityChange: (() -> Void)?

    private var automaticChecksEnabled = false
    private(set) var canCheckForUpdates = false {
        didSet { menuItems.forEach { $0.isEnabled = canCheckForUpdates } }
    }
    private(set) var isShowingUserInterface = false {
        didSet { onVisibilityChange?() }
    }

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecksEnabled }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
        )
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticChecksEnabled = updater.automaticallyChecksForUpdates }
            }
        ]
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Check for Updates…"), action: #selector(performCheck(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canCheckForUpdates
        menuItems.append(item)
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isShowingUserInterface = true
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    @objc private func performCheck(_ sender: Any?) { checkForUpdates() }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillShowModalAlert() {
        isShowingUserInterface = true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        isShowingUserInterface = true
    }

    func standardUserDriverWillFinishUpdateSession() {
        isShowingUserInterface = false
    }
}
