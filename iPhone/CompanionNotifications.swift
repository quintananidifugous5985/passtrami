import CloudKit
import Observation
import OSLog
import UIKit
import UserNotifications

@MainActor
@Observable
final class CompanionNotifications: NSObject, UNUserNotificationCenterDelegate {
    private enum Action: String {
        case approve = "passtrami.approve"
        case decline = "passtrami.decline"
    }

    private struct Intent {
        let requestID: String
        let approve: Bool
    }

    var showsSettings = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private let service: CompanionService
    @ObservationIgnored private var foregroundIntents: [Intent] = []
    @ObservationIgnored private var processingIntent = false
    @ObservationIgnored private var requestingPermission = false

    init(service: CompanionService) {
        self.service = service
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: Action.approve.rawValue,
                                           title: String(localized: "Approve"), options: [.foreground])
        let decline = UNNotificationAction(identifier: Action.decline.rawValue,
                                           title: String(localized: "Decline"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: CompanionService.notificationCategory,
                                   actions: [approve, decline], intentIdentifiers: [], options: [])
        ])
        #if DEBUG
        center.getNotificationCategories { categories in
            let category = categories.first { $0.identifier == "passtrami.approval" }
            let action = category?.actions.first { $0.identifier == "passtrami.approve" }
            CompanionDiagnostics.record("configured category=\(category != nil) approveForeground=\(action?.options.contains(.foreground) == true)")
        }
        #endif
    }

    func becameActive() async {
        #if DEBUG
        CompanionDiagnostics.record("becameActive begin")
        #endif
        await service.refresh()
        await updateAuthorization()
        if service.pairedDevice != nil { await requestPermissionAfterPairing() }
        await processForegroundIntent()
        #if DEBUG
        CompanionDiagnostics.record("becameActive end")
        #endif
    }

    func requestPermissionAfterPairing() async {
        guard service.pairedDevice != nil, !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await updateAuthorization()
        #if DEBUG
        CompanionDiagnostics.record("apns registration requested authorization=\(authorizationStatus.rawValue)")
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }

    func serviceBecameIdle() async {
        await processForegroundIntent()
    }

    private func updateAuthorization() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        #if DEBUG
        CompanionDiagnostics.record("notification foreground categoryMatch=\(notification.request.content.categoryIdentifier == "passtrami.approval")")
        #endif
        Task { @MainActor in
            // UIKit's notification completion must return on the main actor.
            // Show the notification before refreshing the request list.
            completionHandler([.banner, .list, .sound])
            await service.remoteChanged()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let requestID = Self.requestID(from: response.notification.request.content.userInfo)
        let action = response.actionIdentifier
        #if DEBUG
        let knownAction: String
        switch action {
        case "passtrami.approve": knownAction = "approve"
        case "passtrami.decline": knownAction = "decline"
        case UNNotificationDefaultActionIdentifier: knownAction = "open"
        case UNNotificationDismissActionIdentifier: knownAction = "dismiss"
        default: knownAction = "unknown"
        }
        CompanionDiagnostics.record("notification response action=\(knownAction) categoryMatch=\(response.notification.request.content.categoryIdentifier == "passtrami.approval") validRequestID=\(requestID != nil)")
        #endif
        Task { @MainActor in
            await receive(requestID: requestID, actionIdentifier: action)
            #if DEBUG
            CompanionDiagnostics.record("notification response completed on main actor")
            #endif
            completionHandler()
        }
    }

    private func receive(requestID: String?, actionIdentifier: String) async {
        guard let requestID else {
            await service.remoteChanged()
            return
        }
        switch actionIdentifier {
        case Action.decline.rawValue:
            await service.remoteChanged()
            await service.decline(requestID: requestID)
        case Action.approve.rawValue, UNNotificationDefaultActionIdentifier:
            showsSettings = false
            foregroundIntents.append(Intent(requestID: requestID, approve: actionIdentifier == Action.approve.rawValue))
            #if DEBUG
            CompanionDiagnostics.record("intent queued active=\(UIApplication.shared.applicationState == .active) busy=\(service.isBusy)")
            #endif
            if UIApplication.shared.applicationState == .active {
                await processForegroundIntent()
            }
        default:
            break
        }
    }

    private func processForegroundIntent() async {
        #if DEBUG
        if !foregroundIntents.isEmpty {
            CompanionDiagnostics.record("intent processing attempt active=\(UIApplication.shared.applicationState == .active) busy=\(service.isBusy) processing=\(processingIntent)")
        }
        #endif
        guard !processingIntent, !service.isBusy, !foregroundIntents.isEmpty,
              UIApplication.shared.applicationState == .active else { return }
        processingIntent = true
        defer { processingIntent = false }
        while UIApplication.shared.applicationState == .active, !foregroundIntents.isEmpty {
            guard !service.isBusy else { return }
            await service.remoteChanged()
            #if DEBUG
            CompanionDiagnostics.record("intent refreshed active=\(UIApplication.shared.applicationState == .active) busy=\(service.isBusy)")
            #endif
            guard !service.isBusy, UIApplication.shared.applicationState == .active else { return }
            let intent = foregroundIntents.removeFirst()
            guard intent.approve else { continue }
            // Only the explicit notification action reaches this path, after the app is active.
            #if DEBUG
            CompanionDiagnostics.record("notification approval begin")
            #endif
            await service.approve(requestID: intent.requestID)
            #if DEBUG
            CompanionDiagnostics.record("notification approval end failed=\(service.errorMessage != nil)")
            #endif
        }
    }

    nonisolated private static func requestID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification else { return nil }
        let identifier = notification.recordFields?["requestID"] as? String ?? notification.recordID?.recordName
        guard let identifier, UUID(uuidString: identifier) != nil else { return nil }
        return identifier
    }
}

#if DEBUG
enum CompanionDiagnostics {
    private static let logger = Logger(subsystem: "io.zats.Passtrami.Companion", category: "Notifications")
    private static let queue = DispatchQueue(label: "io.zats.Passtrami.Companion.Diagnostics")

    // Only fixed stage names, booleans, numeric states, and error domain/code belong here.
    static func record(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        queue.async {
            guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = directory.appendingPathComponent("companion-notifications.log")
            let line = "\(Date().timeIntervalSince1970) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size == 0 || size > 65_536 {
                    try data.write(to: url, options: .atomic)
                } else {
                    let file = try FileHandle(forWritingTo: url)
                    defer { try? file.close() }
                    try file.seekToEnd()
                    try file.write(contentsOf: data)
                }
            } catch { }
        }
    }

    static func recordError(_ event: String, error: any Error) {
        let error = error as NSError
        record("\(event) errorDomain=\(error.domain) errorCode=\(error.code)")
    }
}
#endif
