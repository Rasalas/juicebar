import Foundation
import UserNotifications

struct NotificationPermission: Sendable {
    enum Authorization: Sendable { case authorized, provisional, denied, undetermined }
    var authorization: Authorization
    var banner = false
    var sound = false
    var allowsDelivery: Bool { authorization == .authorized || authorization == .provisional }
}

struct AppNotification: Sendable {
    var id: String
    var title: String
    var body: String
    var sound: Bool
    var accountID: String?
}

/// The same interface covers lifecycle status, explicit permission and delivery.
/// Tests inject an in-memory implementation; no system center is created by AppStore.
protocol AppNotifications: Sendable {
    func permission() async -> NotificationPermission
    func requestAuthorization() async throws -> Bool
    func deliver(_ notification: AppNotification) async throws
}

struct SystemAppNotifications: AppNotifications {
    func permission() async -> NotificationPermission {
        let status = await UNUserNotificationCenter.current().notificationSettings()
        let authorization: NotificationPermission.Authorization
        switch status.authorizationStatus {
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        case .denied: authorization = .denied
        default: authorization = .undetermined
        }
        return NotificationPermission(authorization: authorization,
                                      banner: status.alertSetting == .enabled && status.alertStyle != .none,
                                      sound: status.soundSetting == .enabled)
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func deliver(_ notification: AppNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.body = notification.body
        if notification.sound { content.sound = .default }
        if let account = notification.accountID { content.userInfo = ["account": account] }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }
}
