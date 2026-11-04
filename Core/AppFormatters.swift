//
//  AppFormatters.swift
//  RelationshipCopilot
//
//  复用的日期格式化器。
//  修复报告 B6：原实现在渲染路径内 `DateFormatter()` 新建 4 处
//  （AnalysisView:241、PromisesView:203/209/377），列表滚动时是明确的掉帧源。
//
//  注意：`DateFormatter` 不是线程安全的，因此这里只提供**主线程使用**的静态实例；
//  后台线程需要时请调用 `make(...)` 自建。
//

import Foundation

enum AppFormatters {

    /// 首页/详情：2026年11月2日
    static let dateLong: DateFormatter = make(style: .long, time: .none)

    /// 列表：2026/11/02
    static let dateShort: DateFormatter = make(style: .short, time: .none)

    /// 记录列表：2026年11月2日 15:04
    static let dateTimeMedium: DateFormatter = make(style: .medium, time: .short)

    /// 仅时间：15:04
    static let timeShort: DateFormatter = make(style: .none, time: .short)

    /// 只取"日"的数字（打卡格子里用）。
    /// 固定 locale 保证不会因系统设置被塞进其他文字。
    static let dayOfMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "d"
        return formatter
    }()

    /// 录音计时：02:35
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 相对时间："3 分钟前" / "昨天" / "2026年11月2日"
    ///
    /// 用 `RelativeDateTimeFormatter` 而不是手写字符串，自动跟随语言与日历设置。
    ///
    /// **必须显式设 locale。** 这是本轮真实截图发现的问题：
    /// 界面全中文，但系统语言是英文时，这一行输出 `1 min. ago` ——
    /// 列表副标题里混进半句英文，比整页英文更糟，因为它看起来像 bug。
    /// `unitsStyle = .short` 在中英文下都能保持紧凑，所以保留。
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static func relativeText(for date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 86_400 { return relative.localizedString(for: date, relativeTo: now) }
        return dateLong.string(from: date)
    }

    private static func make(style: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = time
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }
}
