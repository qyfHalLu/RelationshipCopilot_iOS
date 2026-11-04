import SwiftData
import Foundation

// MARK: - 承诺模型
@Model
final class Promise {
    @Attribute(.unique) var id: UUID
    var content: String
    var contentSummary: String?
    var commitmentType: String?  // behavior_change, emotion_control, habit_formation
    var promisor: String         // user, partner
    var promisee: String         // user, partner（历史上也可能存入对方姓名，读取请用 politeAddress）
    var level: String            // core, normal, recorded
    var trackingStatus: String   // active, paused, closed
    var committedAt: Date
    var deadline: Date?
    var recurrence: String?      // once, daily, weekly, monthly
    var fulfillmentRate: Double
    var streakDays: Int
    var lastCheckIn: Date?
    var confidenceScore: Double?
    var strength: String?        // strong, medium, weak
    var createdAt: Date
    var updatedAt: Date

    @Relationship
    var profile: Profile?

    @Relationship(deleteRule: .cascade)
    var fulfillmentRecords: [FulfillmentRecord]?

    init(content: String, promisor: String, promisee: String) {
        self.id = UUID()
        self.content = content
        self.promisor = promisor
        self.promisee = promisee
        self.level = "normal"
        self.trackingStatus = "active"
        self.committedAt = Date()
        self.fulfillmentRate = 0
        self.streakDays = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - 履约记录模型
@Model
final class FulfillmentRecord {
    @Attribute(.unique) var id: UUID
    var recordDate: Date
    var status: String           // fulfilled, partial, pending, missed
    var detectionSource: String? // system_detection, user_self_report, partner_confirm
    var detectionScore: Double?
    var evidence: String?
    var userRating: Int?
    var userNote: String?
    var createdAt: Date

    @Relationship
    var promise: Promise?

    init(recordDate: Date, status: String) {
        self.id = UUID()
        self.recordDate = recordDate
        self.status = status
        self.createdAt = Date()
    }
}

// MARK: - 强类型访问与履约状态机
//
// 修复报告 C6（P1）：原实现中承诺状态只能读不能写 —— PromiseDetailView 没有任何
// 状态变更入口，`fulfillmentRate` / `streakDays` / `lastCheckIn` / `FulfillmentRecord`
// 全仓库零写入，导致完成率恒 0%、首页待办永不清零、「连续天数」徽章恒为 0。
// 下面的方法把「打一次卡」变成一次受控的状态迁移，并同步重算统计字段。

extension Promise {

    var status: PromiseStatus {
        get { PromiseStatus(rawValue: trackingStatus) ?? .active }
        set { trackingStatus = newValue.rawValue }
    }

    /// 展示用的对方称呼。历史数据里 `promisee` 可能存的是关系角色，也可能是姓名。
    var counterpartName: String? {
        if let name = profile?.name, !name.isEmpty { return name }
        return nil
    }

    var isOpen: Bool { status == .active }

    /// 全部履约记录的轻量投影，供纯函数统计使用。
    var entryProjection: [FulfillmentEntry] {
        (fulfillmentRecords ?? []).map {
            FulfillmentEntry(
                day: $0.recordDate,
                status: FulfillmentStatus(rawValue: $0.status) ?? .pending
            )
        }
    }

    /// 当日已有记录（同一天只保留一条口径，避免重复打卡虚增）。
    func existingRecord(on day: Date, calendar: Calendar = .current) -> FulfillmentRecord? {
        let target = calendar.startOfDay(for: day)
        return (fulfillmentRecords ?? []).first {
            calendar.startOfDay(for: $0.recordDate) == target
        }
    }

    /// 撤销某一天的打卡记录。
    ///
    /// ## 为什么需要这个
    ///
    /// 首页的「今天做到了 / 没做到」是一点即生效的：没有确认框（有确认框会让
    /// 每天一次的动作变重），所以**误触必然会发生在真实使用里**。
    /// 而 `streakDays`（连续天数）是这个产品最核心的激励 ——
    /// 一次误点「没做到」，连续记录当场断掉，用户没有任何补救手段。
    ///
    /// 提供撤销而不是加确认框，是因为：确认框每次都打断，
    /// 而误触是很低频的；低频的错误该用可回退来解决，不该用高频的摩擦。
    @discardableResult
    func removeCheckIn(
        on date: Date = Date(),
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> Bool {
        guard let record = existingRecord(on: date, calendar: calendar) else { return false }
        fulfillmentRecords?.removeAll { $0.id == record.id }
        context.delete(record)
        recalculateStats(calendar: calendar)
        updatedAt = Date()
        return true
    }

    /// 记录一次履约（同一自然日内覆盖写），并重算统计字段。
    /// - Parameters:
    ///   - date: 归属日期，默认为今天。
    ///   - status: 履约结果。
    ///   - context: SwiftData 上下文，用于插入新记录。
    @discardableResult
    func recordCheckIn(
        on date: Date = Date(),
        status newStatus: FulfillmentStatus,
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> FulfillmentRecord {
        let day = calendar.startOfDay(for: date)
        let record: FulfillmentRecord
        if let existing = existingRecord(on: day, calendar: calendar) {
            existing.status = newStatus.rawValue
            existing.detectionSource = "user_self_report"
            record = existing
        } else {
            let created = FulfillmentRecord(recordDate: day, status: newStatus.rawValue)
            created.detectionSource = "user_self_report"
            created.promise = self
            context.insert(created)
            var records = fulfillmentRecords ?? []
            records.append(created)
            fulfillmentRecords = records
            record = created
        }
        recalculateStats(calendar: calendar)
        updatedAt = Date()
        return record
    }

    /// 依据全部记录重算 `fulfillmentRate` / `streakDays` / `lastCheckIn`。
    func recalculateStats(referencesDate today: Date = Date(), calendar: Calendar = .current) {
        let summary = FulfillmentStats.summarize(
            entries: entryProjection,
            referencesDate: today,
            calendar: calendar
        )
        fulfillmentRate = summary.rate
        streakDays = summary.streakDays
        lastCheckIn = summary.lastCheckIn
    }

    /// 手动结束承诺（用户主动关闭）。
    func close() {
        status = .closed
        updatedAt = Date()
    }

    /// 重新打开。
    func reopen() {
        status = .active
        updatedAt = Date()
    }

    /// 到期未打卡的记录视为 missed。启动时批量调用。
    /// - Returns: 是否发生了状态变更。
    @discardableResult
    func settleMissedIfNeeded(
        referencesDate today: Date = Date(),
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> Bool {
        guard status == .active, let deadline else { return false }
        guard FulfillmentStats.isOverdue(deadline: deadline, referencesDate: today, calendar: calendar) else {
            return false
        }
        // 截止日当天或之前都没有任何记录 → 补一条 missed，让完成率与 UI 口径一致
        if (fulfillmentRecords ?? []).isEmpty {
            let created = FulfillmentRecord(
                recordDate: calendar.startOfDay(for: deadline),
                status: FulfillmentStatus.missed.rawValue
            )
            created.detectionSource = "system_detection"
            created.promise = self
            context.insert(created)
            var records = fulfillmentRecords ?? []
            records.append(created)
            fulfillmentRecords = records
            recalculateStats(referencesDate: today, calendar: calendar)
            updatedAt = Date()
            return true
        }
        return false
    }
}

/// 承诺状态。持久化为 String，与存量 `trackingStatus` 值兼容。
enum PromiseStatus: String, Sendable {
    case active
    case paused
    case closed

    var displayName: String {
        switch self {
        case .active:  return "进行中"
        case .paused:  return "已暂停"
        case .closed:  return "已完成"
        }
    }
}
