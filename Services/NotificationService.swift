import Foundation
import UserNotifications
import UIKit

// MARK: - 通知服务
//
// 修复报告 C6 / B / D：
//  - 原实现在 `private init()` 里直接 `requestAuthorization()`（第 8-10 行），
//    一旦该服务被首次访问就会在启动瞬间弹权限框——用户还不知道 App 要做什么。
//    现改为「由调用方在合适的时机显式申请」（创建第一个承诺后）。
//  - 纪念日提醒已**整体删除**：`Profile.birthday` / `.anniversary` / `.knownSince`
//    三个字段一并移除。用户不会用这个 App 记生日 —— 他们有日历和专门的应用，
//    而那些地方的提醒习惯已经沉淀多年。留一个几乎不会用的提醒，只是让
//    「添加人物」变成填表。该功能此前也从未被任何调用点触发过。
//  - 原 `content.badge = 1` 但从不清理角标，红点会永久停留。
//  - 原所有失败只 `print`，用户永远不知道提醒没排上。现统一 `AppLog` + 结果回调。
//  - 该服务此前**全仓库零引用**，所以"承诺提醒/每日提醒/纪念日提醒"三项功能均未生效。

@MainActor
final class NotificationService: NSObject {

    static let shared = NotificationService()

    enum AuthorizationState: Equatable {
        case notDetermined
        case denied
        case authorized
    }

    /// 通知点击回调（由 App 层路由到对应页面）。
    var onOpen: ((_ identifier: String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - 权限

    func authorizationState() async -> AuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default:    return .denied
        }
    }

    /// 显式申请权限。**不要在 App 启动时调用**。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> AuthorizationState {
        let current = await authorizationState()
        guard current == .notDetermined else { return current }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            return granted ? .authorized : .denied
        } catch {
            AppLog.notification.error("Authorization failed: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }

    // MARK: - 承诺提醒

    /// 为一条承诺安排提醒。到期前 1 小时；无截止日期则默认次日上午 9 点。
    func schedulePromiseReminder(_ promise: Promise) {
        let identifier = Self.identifier(for: promise)
        cancel(identifier: identifier)

        guard promise.trackingStatus == PromiseStatus.active.rawValue else { return }

        let counterpart = promise.counterpartName ?? "对方"
        let content = UNMutableNotificationContent()
        content.title = "承诺提醒"
        content.body = "别忘了对 \(counterpart) 的承诺：\(promise.content)"
        content.sound = .default
        content.threadIdentifier = "promise"
        content.userInfo = ["promiseID": promise.id.uuidString]

        let fireDate: Date
        if let deadline = promise.deadline {
            fireDate = deadline.addingTimeInterval(-3600)
        } else {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            fireDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
        guard fireDate > Date() else { return }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        add(identifier: identifier, content: content, trigger: trigger, label: "promise")
    }

    func cancelPromiseReminder(_ promise: Promise) {
        cancel(identifier: Self.identifier(for: promise))
    }

    // MARK: - 每日提醒

    func scheduleDailyReminder(hour: Int = 9) {
        cancel(identifier: Self.dailyIdentifier)

        let body = UNMutableNotificationContent()
        body.title = "今日关系维护"
        body.body = "花一分钟看看今天能为重要的人做点什么。"
        body.sound = .default
        body.threadIdentifier = "daily"

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        add(identifier: Self.dailyIdentifier, content: body, trigger: trigger, label: "daily")
    }

    func cancelDailyReminder() {
        cancel(identifier: Self.dailyIdentifier)
    }

    // MARK: - 复盘回访（支持 N1 的 24 小时回访）

    func scheduleReflectionFollowUp(after hours: Int = 24, sessionID: UUID) {
        let identifier = "reflection-\(sessionID.uuidString)"
        cancel(identifier: identifier)

        let content = UNMutableNotificationContent()
        content.title = "昨天的对话，后来怎么样了？"
        content.body = "花一分钟记录一下结果，能帮你下次更早发现模式。"
        content.sound = .default
        content.threadIdentifier = "reflection"
        content.userInfo = ["sessionID": sessionID.uuidString]

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(60, TimeInterval(hours) * 3600),
            repeats: false
        )
        add(identifier: identifier, content: content, trigger: trigger, label: "reflection")
    }

    // MARK: - 角标

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error {
                AppLog.notification.error("Clear badge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { error in
            if let error {
                AppLog.notification.error("Set badge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 清理

    func clearAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        clearBadge()
    }

    // MARK: - 私有

    private static let dailyIdentifier = "daily-reminder"
    private static func identifier(for promise: Promise) -> String { "promise-\(promise.id.uuidString)" }

    private func cancel(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func add(
        identifier: String,
        content: UNMutableNotificationContent,
        trigger: UNNotificationTrigger,
        label: String
    ) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.notification.error("Schedule \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            } else {
                AppLog.notification.info("Scheduled \(label, privacy: .public)")
            }
        }
    }
}

// MARK: - 前台展示与应用内路由

extension NotificationService: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // 前台也展示横幅：承诺提醒是"此刻要做的事"，不能被吞掉
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run {
            Self.shared.onOpen?(identifier)
            Self.shared.clearBadge()
        }
    }
}
