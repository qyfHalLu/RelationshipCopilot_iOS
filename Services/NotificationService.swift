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
        
        // 检查是否已完成
        guard promise.trackingStatus != "closed" else { return }
        
        let profileName = promise.profile?.name ?? "对方"
        
        let content = UNMutableNotificationContent()
        content.title = "承诺提醒"
        content.body = "别忘了对 \(profileName) 的承诺：\(promise.content)"
        content.sound = .default
        content.badge = 1
        
        // 提醒时间：截止前1小时
        let reminderDate: Date
        if let deadline = promise.deadline {
            reminderDate = deadline.addingTimeInterval(-3600)
        } else {
            // 默认24小时后提醒
            reminderDate = Date().addingTimeInterval(86400)
        }
        
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
                print("承诺提醒已安排: \(promise.content)")
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
        
        // 每天早上9点提醒
        var components = DateComponents()
        components.hour = 9
        components.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "daily-reminder",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("安排每日提醒失败: \(error)")
            }
        }
    }
    
    // MARK: - 安排关系纪念日提醒
    func scheduleAnniversaryReminder(profile: Profile, daysBefore: Int = 3) {
        guard let anniversary = profile.knownSince else { return }
        
        let reminderDate = Calendar.current.date(byAdding: .day, value: -daysBefore, to: anniversary) ?? anniversary
        
        // 忽略已过去的日期
        guard reminderDate > Date() else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "纪念日提醒"
        content.body = "再过\(daysBefore)天是你们认识 \(profile.name) 的纪念日，准备好惊喜了吗？"
        content.sound = .default
        
        let components = Calendar.current.dateComponents([.year, .month, .day], from: reminderDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "anniversary-\(profile.id)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("安排纪念日提醒失败: \(error)")
            }
        }
    }
    
    // MARK: - 清除所有通知
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    // MARK: - 设置角标
    func setBadgeCount(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }
}