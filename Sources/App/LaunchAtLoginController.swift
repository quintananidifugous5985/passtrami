import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController {
    private static let initialDefaultKey = "launchAtLoginInitialDefaultApplied"
    private let service = SMAppService.mainApp
    private(set) var status = SMAppService.mainApp.status
    private(set) var operationError: String?

    func applyInitialDefaultIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.initialDefaultKey) == nil else {
            refresh()
            return
        }
        switch service.status {
        case .notRegistered, .notFound:
            perform { try service.register() }
        case .enabled, .requiresApproval:
            refresh()
        @unknown default:
            refresh()
        }
        if status == .enabled || status == .requiresApproval {
            UserDefaults.standard.set(true, forKey: Self.initialDefaultKey)
        }
    }

    func refresh() {
        let current = service.status
        if current != status { operationError = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            switch service.status {
            case .notRegistered, .notFound:
                perform { try service.register() }
            case .enabled, .requiresApproval:
                refresh()
            @unknown default:
                refresh()
            }
            if status == .requiresApproval { openLoginItems() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            perform { try service.unregister() }
        } else {
            refresh()
        }
        // A direct user choice must not be changed by the first-launch default.
        UserDefaults.standard.set(true, forKey: Self.initialDefaultKey)
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func perform(_ operation: () throws -> Void) {
        operationError = nil
        do { try operation() }
        catch { operationError = error.localizedDescription }
        status = service.status
    }
}
