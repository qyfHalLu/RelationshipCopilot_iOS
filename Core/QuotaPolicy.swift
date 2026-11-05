//
//  QuotaPolicy.swift
//  RelationshipCopilot
//
//  免费额度的判定规则。
//  修复报告 D2：原实现把配额放在 UserDefaults 且只在一半路径上校验
//  （`analyzeConversation` 检查并计数，`generateHealthReport` 完全不检查），
//  导致"留了个后门 + 重装即可重置"。
//
//  本文件只负责**规则**，不负责存储。
//
//  ⚠️ 文件头原有一句「存储由 `AIQuotaStore` 承担，后续可整体替换为服务端
//  实现而不动调用方」——**这个类型不存在**，全仓库只在这一行注释里出现过。
//  真实的存储是 `AIService` 里 UserDefaults 的两个键（`Keys.used` /
//  `Keys.lastDay`），见 `persistQuota()`。所以"换存储不动调用方"这个
//  承诺目前是空的：真要换，得改 `AIService` 本身。
//
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

// ## 已删除：`QuotaSnapshot`
//
// 这个类型**全仓库零引用** —— 它自己的定义，加上注释里的提及，就是全部。
// 真实配额走 `AIService` 的 UserDefaults 两个键，`checkAndResetDailyQuota()`
// 从不构造它。上一轮清理时只处理了它内部的 `fresh(today:)` 函数，
// 把整个类型留了下来；本轮一并删掉。
//
// 保留这段说明而不是直接抹掉，是因为文件头"本文件只管规则、不管存储"
// 这话容易让人以为这里应该有持久化类型。答案是没有 —— 持久化在
// `AIService.persistQuota()`。
