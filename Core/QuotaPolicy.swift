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
///
/// ⚠️ 本类型**全仓库零引用**，是尚未清理的死代码。真实配额不走这里：
/// `AIService` 用 UserDefaults 的两个独立键（`Keys.used` / `Keys.lastDay`，
/// 见 `persistQuota()`）来存，`checkAndResetDailyQuota()` 也只读写那两个键，
/// **从不构造 `QuotaSnapshot`**。
///
/// 注意：本文件头部提到的 `AIQuotaStore` 也已不存在（同样只出现在注释里），
/// 别把它当成"将来会接管存储"的依据。
///
/// 未在本轮删除的原因：本轮增量只清理**函数级**死代码，删整个类型属于
/// 另一次增量，已记入 `WORK_STATE.md` 待办，不要每轮重新"发现"一次。
struct QuotaSnapshot: Codable, Sendable, Equatable {
    var used: Int
    var lastResetDay: Date
}
