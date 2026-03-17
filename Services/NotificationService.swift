import Foundation
import UserNotifications

// MARK: - 通知服务
class NotificationService {
    static let shared = NotificationService()
    
    private init() {
        requestAuthorization()
    }
    
    // MARK: - 请求权限
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("通知权限已获取")
            } else if let error = error {
                print("通知权限请求失败: \(error)")
            }
        }
    }
    
    // MARK: - 检查权限状态
    func checkAuthorizationStatus(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus == .authorized)
            }
        }
    }
    
    // MARK: - 安排承诺提醒
    func schedulePromiseReminder(_ promise: Promise) {
        // 取消现有通知
        cancelPromiseReminder(promise)
        
        guard !promise.isCompleted else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "承诺提醒"
        content.body = "别忘了对 \(promise.relatedProfile?.name ?? "对方") 的承诺：\(promise.title)"
        content.sound = .default
        content.badge = 1
        
        // 提醒时间：截止前1小时
        let reminderDate = promise.dueDate.addingTimeInterval(-3600)
        
        // 如果截止时间已过，不发送
        guard reminderDate > Date() else { return }
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminderDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "promise-\(promise.id)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("安排通知失败: \(error)")
            } else {
                print("承诺提醒已安排: \(promise.title)")
            }
        }
    }
    
    // MARK: - 取消承诺提醒
    func cancelPromiseReminder(_ promise: Promise) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["promise-\(promise.id)"])
    }
    
    // MARK: - 安排每日提醒
    func scheduleDailyReminder() {
        let content = UNMutableNotificationContent()
        content.title = "今日关系维护"
        content.body = "记得查看今天的承诺，维护好你的重要关系 💝"
        content.sound = .default
        
        // 每天晚上8点提醒
        var components = DateComponents()
        components.hour = 20
        components.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "daily-reminder",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("每日提醒安排失败: \(error)")
            }
        }
    }
    
    // MARK: - 安排每周报告
    func scheduleWeeklyReport() {
        let content = UNMutableNotificationContent()
        content.title = "本周关系报告"
        content.body = "查看本周的关系健康度分析和改进建议 📊"
        content.sound = .default
        
        // 每周日晚上8点
        var components = DateComponents()
        components.weekday = 1 // 周日
        components.hour = 20
        components.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "weekly-report",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("每周报告提醒安排失败: \(error)")
            }
        }
    }
    
    // MARK: - 发送即时通知
    func sendImmediateNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // 立即发送
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - 取消所有通知
    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
