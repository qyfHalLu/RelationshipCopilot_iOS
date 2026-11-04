//
//  DataMaintenance.swift
//  RelationshipCopilot
//
//  启动时的数据自检与修复。
//
//  对应报告：
//   - R6：旧版 setter 会把 `intimacyScore` 写成负数，存量数据需要修复。
//         （`healthScore` 本身已在改版中删除，见 Core/RelationshipHealth.swift 的删除说明；
//          但 `intimacyScore` 仍是"亲密度"的存储字段，负值修复继续保留。）
//   - C6：到期未打卡的承诺需要转成 `missed`，否则完成率口径永远失真。
//   - B3：异常退出会遗留录音文件，启动时清理。
//   - Widget：主 App 从未写入 App Group，导致小组件永远显示假分数。
//   - 角标：通知角标此前只增不减。
//
//  所有操作都是幂等的，重复执行安全。
//

import Foundation
import SwiftData

@MainActor
enum DataMaintenance {

    struct Report {
        var repairedProfiles = 0
        var settledPromises = 0
        var removedAudioFiles = 0
        var widgetSynced = false
    }

    @discardableResult
    static func run(context: ModelContext, now: Date = Date()) -> Report {
        var report = Report()

        // 1) 修复被写坏的亲密度
        if let profiles = try? context.fetch(FetchDescriptor<Profile>()) {
            for profile in profiles where profile.repairIntimacyIfNeeded() {
                report.repairedProfiles += 1
            }
        }

        // 2) 结算到期未打卡的承诺
        if let promises = try? context.fetch(
            FetchDescriptor<Promise>(predicate: #Predicate { $0.trackingStatus == "active" })
        ) {
            for promise in promises
            where promise.settleMissedIfNeeded(referencesDate: now, in: context) {
                report.settledPromises += 1
            }
        }

        if report.repairedProfiles > 0 || report.settledPromises > 0 {
            do {
                try context.save()
            } catch {
                AppLog.persistence.error("Maintenance save failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 3) 清理遗留音频
        report.removedAudioFiles = RecordingService.cleanupOrphanRecordings()

        // 4) 同步 Widget
        report.widgetSynced = syncWidget(context: context)

        // 5) 清理角标
        NotificationService.shared.clearBadge()

        AppLog.app.info(
            "Maintenance: repaired=\(report.repairedProfiles, privacy: .public) settled=\(report.settledPromises, privacy: .public) audio=\(report.removedAudioFiles, privacy: .public) widget=\(report.widgetSynced, privacy: .public)"
        )
        return report
    }

    /// 把真实计数写入 App Group，供 Widget 展示。
    ///
    /// 改版（删除关系健康度）：原实现写的是 `profile.healthScore`，即
    /// `70 + intimacy * 3` —— 用户自己拖滑块的值。Widget 因此成为伪指标曝光
    /// 最频繁的地方。现在写入三个可数的量，任何一个都能指到具体数据。
    @discardableResult
    static func syncWidget(context: ModelContext, now: Date = Date()) -> Bool {
        var descriptor = FetchDescriptor<Profile>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1

        guard let profile = try? context.fetch(descriptor).first else {
            WidgetDataStore.update(.empty)
            return true
        }

        // 待打卡：属于此人、进行中、今天还没有任何履约记录的承诺
        let pendingPromises = (profile.promises ?? []).filter { promise in
            promise.status == .active && promise.existingRecord(on: now) == nil
        }.count

        // 进行中的评理：还没走到 closed / blocked 的
        let allCases = (try? context.fetch(FetchDescriptor<DisputeCase>())) ?? []
        let mine = allCases.filter { $0.profile?.id == profile.id || $0.profile == nil }
        let activeCases = mine.filter { $0.state.isCollecting || $0.state == .ready }.count
        let lastCaseAt = mine.compactMap { $0.state == .closed ? $0.updatedAt : nil }.max()

        let latestSession = (profile.recordingSessions ?? [])
            .compactMap(\.endedAt)
            .max()

        WidgetDataStore.update(
            WidgetDataStore.Snapshot(
                profileName: profile.name,
                pendingPromiseCount: pendingPromises,
                activeCaseCount: activeCases,
                lastCaseAt: lastCaseAt,
                lastAnalysisAt: latestSession,
                hasNewNotifications: false
            )
        )
        return true
    }
}
