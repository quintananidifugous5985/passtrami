import AppKit
import Observation

@MainActor
@Observable
final class FullDiskAccessModel {
    typealias Status = FullDiskAccessCheck.Status

    private(set) var status: Status = .required
    private(set) var settingsOpenFailed = false
    @ObservationIgnored private let check: () -> Status
    @ObservationIgnored var onCheckAgain: (() -> Void)?

    init(check: @escaping () -> Status = { FullDiskAccessCheck.checkRequiredLocation() }) {
        self.check = check
    }

    @discardableResult
    func refresh() -> Bool {
        status = check()
        return status == .available
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        settingsOpenFailed = !NSWorkspace.shared.open(url)
    }

    func checkAgain() { onCheckAgain?() }

}
