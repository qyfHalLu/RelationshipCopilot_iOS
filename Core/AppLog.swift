//
//  AppLog.swift
//  RelationshipCopilot
//
//  统一日志出口，替代散落的 `print`（修复报告 A4：6 处 print 无法在真机排查）。
//  使用 `os.Logger`：可在 Console.app / Xcode Organizer 中按 subsystem + category 过滤，
//  且默认不进入 release 日志流，不影响性能。
//

import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.relationshipcopilot.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let notification = Logger(subsystem: subsystem, category: "notification")
    static let widget = Logger(subsystem: subsystem, category: "widget")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

/// 隐私安全的日志辅助：不打印录音文本、手机号等敏感内容。
///
/// 说明：原先这里还有一个 `textLength(_:)`（只记录文本长度），全仓库零调用，
/// 已删除。`maskedPhone` 是真正在用的一条 —— 登录页和「我的」页面都靠它
/// 把手机号显示成 `138****8888`，删它会把完整手机号暴露在界面上。
enum SafeLog {
    /// 手机号脱敏：138****8888。
    static func maskedPhone(_ phone: String) -> String {
        guard phone.count >= 7 else { return "***" }
        let head = phone.prefix(3)
        let tail = phone.suffix(4)
        return "\(head)****\(tail)"
    }
}
