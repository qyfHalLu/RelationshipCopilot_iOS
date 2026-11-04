//
//  WidgetDataStore.swift
//  RelationshipCopilot
//
//  Widget 与主 App 之间的唯一数据出口（App Group）。
//
//  改版说明（删除关系健康度）：
//  原实现写入 `widgetHealthScore`，Widget 显示「关系健康 85 / 100」。
//  那个分数是 `70 + intimacy * 3` —— 用户自己拖滑块的值，没有任何测量含义。
//  把它显示在桌面上，是全产品**暴露面积最大**的一处伪指标：用户一天要看几十次。
//
//  现在改成三个真实可数的量：
//   - 待打卡承诺数（今天还没打卡、且未过期的）
//   - 进行中的评理件数（写到一半或已就绪未查看）
//   - 最近一次评理距今多久
//  这三个都是"数出来的"，不是"估出来的"，Widget 上不需要任何解释性免责。
//

import Foundation
import WidgetKit

enum WidgetDataStore {

    static let appGroupID = "group.com.relationshipcopilot.app"

    private enum Keys {
        static let profileName = "widgetProfileName"
        static let pendingPromiseCount = "widgetPendingPromiseCount"
        static let activeCaseCount = "widgetActiveCaseCount"
        static let lastCaseAt = "widgetLastCaseAt"
        static let lastAnalysis = "widgetLastAnalysis"
        static let hasNewNotifications = "widgetHasNewNotifications"
        static let hasData = "widgetHasData"
    }

    /// Widget 侧读取用的快照。与写入侧字段一一对应，改这里必须同步 Widget。
    struct Snapshot: Equatable {
        var profileName: String?
        var pendingPromiseCount: Int
        var activeCaseCount: Int
        var lastCaseAt: Date?
        var lastAnalysisAt: Date?
        var hasNewNotifications: Bool

        var hasData: Bool { profileName?.isEmpty == false }

        static let empty = Snapshot(
            profileName: nil,
            pendingPromiseCount: 0,
            activeCaseCount: 0,
            lastCaseAt: nil,
            lastAnalysisAt: nil,
            hasNewNotifications: false
        )
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// 写入快照并刷新 Widget。没有档案时传 nil，Widget 显示引导态而不是假数字。
    static func update(_ snapshot: Snapshot) {
        guard let defaults else {
            AppLog.widget.error("App Group unavailable: \(appGroupID, privacy: .public)")
            return
        }

        guard let name = snapshot.profileName, !name.isEmpty else {
            clear(defaults: defaults)
            reload()
            return
        }

        defaults.set(true, forKey: Keys.hasData)
        defaults.set(name, forKey: Keys.profileName)
        defaults.set(snapshot.pendingPromiseCount, forKey: Keys.pendingPromiseCount)
        defaults.set(snapshot.activeCaseCount, forKey: Keys.activeCaseCount)

        if let lastCaseAt = snapshot.lastCaseAt {
            defaults.set(lastCaseAt.timeIntervalSince1970, forKey: Keys.lastCaseAt)
        } else {
            defaults.removeObject(forKey: Keys.lastCaseAt)
        }
        if let lastAnalysisAt = snapshot.lastAnalysisAt {
            defaults.set(lastAnalysisAt.timeIntervalSince1970, forKey: Keys.lastAnalysis)
        } else {
            defaults.removeObject(forKey: Keys.lastAnalysis)
        }
        defaults.set(snapshot.hasNewNotifications, forKey: Keys.hasNewNotifications)
        reload()
    }

    /// 读取（App 内调试/设置页展示用；Widget 侧自行读取同一组键）。
    static func snapshot() -> Snapshot {
        guard let defaults, defaults.bool(forKey: Keys.hasData),
              let name = defaults.string(forKey: Keys.profileName), !name.isEmpty else {
            return .empty
        }
        let caseTimestamp = defaults.double(forKey: Keys.lastCaseAt)
        let analysisTimestamp = defaults.double(forKey: Keys.lastAnalysis)
        return Snapshot(
            profileName: name,
            pendingPromiseCount: defaults.integer(forKey: Keys.pendingPromiseCount),
            activeCaseCount: defaults.integer(forKey: Keys.activeCaseCount),
            lastCaseAt: caseTimestamp > 0 ? Date(timeIntervalSince1970: caseTimestamp) : nil,
            lastAnalysisAt: analysisTimestamp > 0 ? Date(timeIntervalSince1970: analysisTimestamp) : nil,
            hasNewNotifications: defaults.bool(forKey: Keys.hasNewNotifications)
        )
    }

    static func clear() {
        guard let defaults else { return }
        clear(defaults: defaults)
        reload()
    }

    private static func clear(defaults: UserDefaults) {
        defaults.set(false, forKey: Keys.hasData)
        defaults.removeObject(forKey: Keys.profileName)
        defaults.removeObject(forKey: Keys.pendingPromiseCount)
        defaults.removeObject(forKey: Keys.activeCaseCount)
        defaults.removeObject(forKey: Keys.lastCaseAt)
        defaults.removeObject(forKey: Keys.lastAnalysis)
        defaults.removeObject(forKey: Keys.hasNewNotifications)
    }

    private static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
