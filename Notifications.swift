import Foundation
import UserNotifications

enum NotificationSendError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        "通知未授权：请在系统设置 › 通知 中允许 AI Lock 发送通知。"
    }
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() { super.init() }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            log("通知权限状态：\(settings.authorizationStatus.rawValue)")
        }
    }

    func requestAuthorization(completion: @escaping (UNAuthorizationStatus) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    log("请求通知授权：granted=\(granted) error=\(error?.localizedDescription ?? "无")")
                    center.getNotificationSettings { updated in
                        DispatchQueue.main.async { completion(updated.authorizationStatus) }
                    }
                }
            default:
                DispatchQueue.main.async { completion(settings.authorizationStatus) }
            }
        }
    }

    func sendTestNotification(completion: @escaping (Result<Void, Error>) -> Void) {
        requestAuthorization { status in
            guard status == .authorized || status == .provisional else {
                completion(.failure(NotificationSendError.notAuthorized))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = L10n.text("AI Lock 测试通知")
            content.body = L10n.text("通知权限已配置，可收到资源预警。")
            content.sound = .default
            let request = UNNotificationRequest(identifier: "ailock.test.\(UUID().uuidString)",
                                                content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false))
            UNUserNotificationCenter.current().add(request) { error in
                log("测试通知 add 结果：\(error?.localizedDescription ?? "成功")")
                DispatchQueue.main.async { completion(error.map { .failure($0) } ?? .success(())) }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
