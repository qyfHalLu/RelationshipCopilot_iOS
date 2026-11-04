//
//  FulfillmentStats.swift
//  RelationshipCopilot
//
//  承诺履约统计的唯一计算入口。
//  修复报告 C6：承诺详情页没有任何状态变更入口，fulfillmentRate / streakDays / lastCheckIn
//  全仓库零写入 → 完成率恒 0%、首页待办永不清零、「连续天数」徽章恒为 0。
//
//  纯函数、无框架依赖，可直接单测。
//

import Foundation

/// 履约状态。持久化为 `String`，与 `FulfillmentRecord.status` 存量值兼容。
enum FulfillmentStatus: String, CaseIterable, Sendable {
    case fulfilled
    case partial
    case pending
    case missed

    var displayName: String {
        switch self {
        case .fulfilled: return "已做到"
        case .partial:   return "部分做到"
        case .pending:   return "待确认"
        case .missed:    return "未做到"
        }
    }

    /// 计入完成率的权重。pending 不计入分母。
    var credit: Double {
        switch self {
        case .fulfilled: return 1.0
        case .partial:   return 0.5
        case .missed:    return 0.0
        case .pending:   return 0.0
        }
    }

    var countsTowardRate: Bool { self != .pending }
}

/// 一条履约记录的轻量投影（用于脱离 SwiftData 做纯计算）。
struct FulfillmentEntry: Sendable, Equatable {
    let day: Date
    let status: FulfillmentStatus

    init(day: Date, status: FulfillmentStatus) {
        self.day = day
        self.status = status
    }
}

/// 履约统计结果。
struct FulfillmentSummary: Sendable, Equatable {
    /// 统计样本数（已排除 pending）。
    let sampleCount: Int
    let fulfilledCount: Int
    let missedCount: Int
    let partialCount: Int
    /// 完成率 0...1。无样本时为 0。
    let rate: Double
    /// 连续达标天数（从今天或昨天往前数 fulfilled）。
    let streakDays: Int
    /// 最近一次打卡日期。
    let lastCheckIn: Date?

    static let empty = FulfillmentSummary(
        sampleCount: 0, fulfilledCount: 0, missedCount: 0, partialCount: 0,
        rate: 0, streakDays: 0, lastCheckIn: nil
    )

    var percentText: String { "\(Int((rate * 100).rounded()))%" }
}

enum FulfillmentStats {

    /// 计算统计。`referencesDate` 用于确定「今天」，便于测试注入。
    static func summarize(
        entries: [FulfillmentEntry],
        referencesDate today: Date = Date(),
        calendar: Calendar = .current
    ) -> FulfillmentSummary {
        guard !entries.isEmpty else { return .empty }

        let counted = entries.filter { $0.status.countsTowardRate }

        let fulfilled = counted.filter { $0.status == .fulfilled }.count
        let partial = counted.filter { $0.status == .partial }.count
        let missed = counted.filter { $0.status == .missed }.count

        let credit = counted.reduce(0.0) { $0 + $1.status.credit }
        let rate = counted.isEmpty ? 0 : min(1.0, max(0.0, credit / Double(counted.count)))

        let lastCheckIn = entries
            .filter { $0.status == .fulfilled || $0.status == .partial }
            .map(\.day)
            .max()

        return FulfillmentSummary(
            sampleCount: counted.count,
            fulfilledCount: fulfilled,
            missedCount: missed,
            partialCount: partial,
            rate: rate,
            streakDays: streak(entries: counted, referencesDate: today, calendar: calendar),
            lastCheckIn: lastCheckIn
        )
    }

    /// 连续达标天数。
    ///
    /// 规则：从「今天」或「昨天」起往前逐日回溯，当天必须是 fulfilled。
    /// 允许今天还没打卡（从昨天起算），避免用户早上打开 App 就被告知"连续 0 天"。
    /// 同一天多条记录时，取当天最好的一条（存在 fulfilled 即视为达标）。
    static func streak(
        entries: [FulfillmentEntry],
        referencesDate today: Date,
        calendar: Calendar = .current
    ) -> Int {
        let fulfilledDays = Set(
            entries
                .filter { $0.status == .fulfilled }
                .map { calendar.startOfDay(for: $0.day) }
        )
        guard !fulfilledDays.isEmpty else { return 0 }

        let startOfToday = calendar.startOfDay(for: today)
        var cursor: Date

        if fulfilledDays.contains(startOfToday) {
            cursor = startOfToday
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
                  fulfilledDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while fulfilledDays.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
            if count > 3650 { break }  // 防御性上限
        }
        return count
    }

    /// 判断一条承诺是否已到期（用于把 pending 转 missed）。
    static func isOverdue(deadline: Date?, referencesDate today: Date, calendar: Calendar = .current) -> Bool {
        guard let deadline else { return false }
        return calendar.startOfDay(for: deadline) < calendar.startOfDay(for: today)
    }

    /// 按天去重后返回最近 N 天的打卡序列，供周报/图表使用。
    static func recentDays(
        entries: [FulfillmentEntry],
        days: Int,
        referencesDate today: Date,
        calendar: Calendar = .current
    ) -> [(day: Date, status: FulfillmentStatus?)] {
        guard days > 0 else { return [] }
        let startOfToday = calendar.startOfDay(for: today)
        var best: [Date: FulfillmentStatus] = [:]
        for entry in entries {
            let key = calendar.startOfDay(for: entry.day)
            let existing = best[key]
            if existing == nil || entry.status.credit > (existing?.credit ?? -1) {
                best[key] = entry.status
            }
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else { return nil }
            return (day, best[day])
        }
    }
}
