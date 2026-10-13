import Foundation
import UserNotifications
import AppKit

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "thread"
    var onOpen: ((String) -> Void)?
    var onDone: ((String) -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let done = UNNotificationAction(identifier: "done", title: "Mark done", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [open, done], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            logger.info("notification permission granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
        center.getNotificationSettings { s in
            logger.info("notification settings: auth=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue) style=\(s.alertStyle.rawValue)")
        }
    }

    func postTest() {
        let c = UNMutableNotificationContent()
        c.title = "GitMenu is working"
        c.subtitle = "kelvinamoaba/gitmenu #1"
        c.body = "You will see new GitHub activity here."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test-\(UUID())", content: c, trigger: nil)) { e in
            logger.info("test notification posted error=\(e?.localizedDescription ?? "none")")
        }
    }

    func post(thread: NotificationThread, details: ThreadDetails?, sound: Bool = true, note: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = thread.subject.title
        var sub = thread.repository.fullName
        if let n = details?.number { sub += " #\(n)" }
        c.subtitle = sub
        var body = Reason.phrase(thread.reason)
        if let a = details?.latestActivity, abs(a.createdAt.timeIntervalSince(thread.updatedAt)) < 120 {
            let who = a.author?.login ?? "Someone"
            let snippet = a.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            body = snippet.isEmpty ? "\(who): \(a.kind)" : "\(who): \(snippet)"
        }
        c.body = note ?? body
        c.categoryIdentifier = Self.category
        c.userInfo = ["threadId": thread.id]
        c.threadIdentifier = thread.repository.fullName
        c.sound = sound && Reason.urgent.contains(thread.reason) ? .default : nil
        let new = details?.newActivities(since: thread.lastReadAt).count ?? 0
        if new > 1, note == nil { c.title = "\(new) new · " + thread.subject.title }
        let req = UNNotificationRequest(identifier: "thread-\(thread.id)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { e in
            logger.info("posted notification for \(thread.id) error=\(e?.localizedDescription ?? "none")")
        }
    }

    func clear(threadId: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            let ids = list.filter { ($0.request.content.userInfo["threadId"] as? String) == threadId }.map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["threadId"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            if action == "done" { onDone?(id) } else { onOpen?(id) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
