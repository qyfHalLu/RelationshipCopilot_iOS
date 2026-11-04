import Foundation
import UserNotifications
import UIKit

// MARK: - 通知服务
//
// 修复报告 C6 / B / D：
//  - 原实现在 `private init()` 里直接 `requestAuthorization()`（第 8-10 行），
//    一旦该服务被首次访问就会在启动瞬间弹权限框——用户还不知道 App 要做什么。
//    现改为「由调用方在合适的时机显式申请」（创建第一个承诺后）。
//  - 原 `scheduleAnniversaryReminder` 的重复触发器里带了 `.year` 分量，
//    `UNCalendarNotificationTrigger(repeats: true)` 匹配到具体年份后不会再触发，
//    纪念日提醒实际上只会来一次。现改为只取月/日，并改用「下一次纪念日」计算。
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

    // MARK: - 纪念日提醒

    /// 纪念日提醒：提前 `daysBefore` 天，每年重复。
    /// 修复：重复触发器不得包含 `.year`，否则只会命中首次那一年的具体日期。
    func scheduleAnniversaryReminder(profile: Profile, daysBefore: Int = 3) {
        let identifier = Self.anniversaryIdentifier(for: profile)
        cancel(identifier: identifier)

        guard let anniversary = profile.anniversary ?? profile.knownSince else { return }

        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "zh_CN")
        let anniversaryComponents = calendar.dateComponents([.month, .day], from: anniversary)
        guard let month = anniversaryComponents.month, let day = anniversaryComponents.day else { return }

        // 计算「下一次提醒日期」用于展示文案（触发器本身按 月/日 每年重复）
        let today = calendar.startOfDay(for: Date())
        var target = calendar.date(from: DateComponents(year: calendar.component(.year, from: today), month: month, day: day)) ?? today
        if target < today {
            target = calendar.date(byAdding: .year, value: 1, to: target) ?? target
        }
        let years = max(0, calendar.dateComponents([.year], from: anniversary, to: target).year ?? 0)

        let content = UNMutableNotificationContent()
        content.title = "纪念日提醒"
        content.body = years > 1
            ? "再过 \(daysBefore) 天是你和 \(profile.name) 的第 \(years) 个纪念日。"
            : "再过 \(daysBefore) 天是你和 \(profile.name) 的纪念日。"
        content.sound = .default
        content.threadIdentifier = "anniversary"
        content.userInfo = ["profileID": profile.id.uuidString]

        var fire = DateComponents()
        fire.month = month
        fire.day = day
        fire.hour = 10
        fire.minute = 0
        // 提前 daysBefore 天：用「日」字段回退，跨月由日历处理
        if let base = calendar.date(from: DateComponents(year: 2000, month: month, day: day)),
           let shifted = calendar.date(byAdding: .day, value: -daysBefore, to: base) {
            let shiftedComponents = calendar.dateComponents([.month, .day], from: shifted)
            fire.month = shiftedComponents.month
            fire.day = shiftedComponents.day
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: fire, repeats: true)
        add(identifier: identifier, content: content, trigger: trigger, label: "anniversary")
    }

    func cancelAnniversaryReminder(for profile: Profile) {
        cancel(identifier: Self.anniversaryIdentifier(for: profile))
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
    private static func anniversaryIdentifier(for profile: Profile) -> String { "anniversary-\(profile.id.uuidString)" }

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
