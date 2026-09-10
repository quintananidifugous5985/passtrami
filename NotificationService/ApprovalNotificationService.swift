import UserNotifications

final class ApprovalNotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard request.content.categoryIdentifier == "passtrami.approval",
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        content.interruptionLevel = .timeSensitive
        contentHandler(content)
    }
}
