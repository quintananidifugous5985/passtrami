import SwiftUI
import UIKit

@main
struct PasstramiCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CompanionRootView(service: delegate.service, notifications: delegate.notifications)
                .task { await delegate.notifications.becameActive() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        #if DEBUG
                        CompanionDiagnostics.record("scene active")
                        #endif
                        delegate.service.start()
                        Task { await delegate.notifications.becameActive() }
                    case .background:
                        #if DEBUG
                        CompanionDiagnostics.record("scene background")
                        #endif
                        delegate.service.stop()
                    case .inactive:
                        #if DEBUG
                        CompanionDiagnostics.record("scene inactive")
                        #endif
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    let service = CompanionService(role: .phone)
    lazy var notifications = CompanionNotifications(service: service)

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        CompanionDiagnostics.record("application launched")
        #endif
        notifications.configure()
        service.start()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        #if DEBUG
        CompanionDiagnostics.record("remote notification delivered")
        #endif
        let previous = service.pendingRequests.map(\.id)
        await service.remoteChanged()
        return previous == service.pendingRequests.map(\.id) ? .noData : .newData
    }

    #if DEBUG
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        CompanionDiagnostics.record("apns registered")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        CompanionDiagnostics.recordError("apns registration failed", error: error)
    }
    #endif
}
