//
//  QuotaPolicy.swift
//  RelationshipCopilot
//
//  免费额度的判定规则。
//  修复报告 D2：原实现把配额放在 UserDefaults 且只在一半路径上校验
//  （`analyzeConversation` 检查并计数，`generateHealthReport` 完全不检查），
//  导致"留了个后门 + 重装即可重置"。
//
//  本文件只负责**规则**，不负责存储；存储由 `AIQuotaStore` 承担，
//  后续可整体替换为服务端实现而不动调用方。
//  纯函数、无框架依赖，可直接单测。
//

import Foundation

struct QuotaPolicy: Sendable, Equatable {
    /// 每个周期允许的免费次数。
    let limit: Int

    static let `default` = QuotaPolicy(limit: 10)

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func remaining(used: Int) -> Int {
        max(0, limit - max(0, used))
    }

    func isExhausted(used: Int) -> Bool {
        remaining(used: used) <= 0
    }

    /// 是否已跨天，需要把计数归零。
    static func shouldReset(lastResetDay: Date?, today: Date, calendar: Calendar = .current) -> Bool {
        guard let lastResetDay else { return true }
        return calendar.startOfDay(for: lastResetDay) < calendar.startOfDay(for: today)
    }
}

/// 配额快照（可持久化）。
struct QuotaSnapshot: Codable, Sendable, Equatable {
    var used: Int
    var lastResetDay: Date

    // 说明：`fresh(today:)` 已删除（全仓库零调用）。
    // 快照的实际生成在 `AIService.checkAndResetDailyQuota()` 里。
}
