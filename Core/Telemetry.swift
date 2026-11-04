//
//  Telemetry.swift
//  RelationshipCopilot
//
//  修复报告 E5 / R：App 内既无埋点也无崩溃上报，导致"漏斗断在哪一步"无法测量。
//  这里提供一个**零第三方依赖**的最小埋点：只记录事件计数与首次发生时间，
//  不含任何对话内容、手机号等敏感信息（隐私清单里因此无需申报"跟踪"）。
//
//  后续接入真实后端时，把 `flush()` 接到上传接口即可，调用方不需要改。
//

import Foundation
import os

enum TelemetryEvent: String, CaseIterable, Sendable {
    case appLaunched
    case loginScreenShown
    case loginCompleted
    case profileCreated
    case profileEdited
    case promiseCreated
    case promiseCheckedIn
    case promiseClosed
    case recordingStarted
    case recordingCancelled
    case analysisSucceeded
    case analysisFailed
    case quickToolOpened
    case settingsOpened
    case paywallShown
    case onboardingCompleted
    case dataExported
    case accountDeleted

    // 评理（本次改版的主力路径）
    case disputeStarted
    case disputeSideSubmitted
    case disputeEvaluated
    case disputeBlocked
    case disputeDegraded
    /// 把评理结果沉淀成了一条承诺。
    ///
    /// 单独记这个事件、而不是复用 `promiseCreated`，是因为它衡量的是
    /// **闭环转化率**：有多少次评理真正走到了"明天有事可做"。
    /// 这是本产品相对参考产品（判决即终止）唯一的留存机制，
    /// 混进 `promiseCreated` 就再也看不出这条链通不通。
    case disputeAdoptedAsPromise
}

@MainActor
final class Telemetry {

    static let shared = Telemetry()

    private let defaults: UserDefaults
    private let prefix = "telemetry."
    private let firstLaunchKey = "telemetry.firstLaunchAt"
    private let sessionCountKey = "telemetry.sessionCount"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: firstLaunchKey) == nil {
            defaults.set(Date(), forKey: firstLaunchKey)
        }
    }

    /// 记录一次事件。
    func track(_ event: TelemetryEvent) {
        let countKey = prefix + event.rawValue
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)

        let firstKey = prefix + event.rawValue + ".firstAt"
        if defaults.object(forKey: firstKey) == nil {
            defaults.set(Date(), forKey: firstKey)
        }
        AppLog.app.debug("event=\(event.rawValue, privacy: .public) count=\(count, privacy: .public)")
    }

    /// 记录一次冷启动。
    func trackLaunch() {
        defaults.set(defaults.integer(forKey: sessionCountKey) + 1, forKey: sessionCountKey)
        track(.appLaunched)
    }

    func count(of event: TelemetryEvent) -> Int {
        defaults.integer(forKey: prefix + event.rawValue)
    }

    func hasEverFired(_ event: TelemetryEvent) -> Bool {
        count(of: event) > 0
    }

    var firstLaunchAt: Date? {
        defaults.object(forKey: firstLaunchKey) as? Date
    }

    var sessionCount: Int {
        defaults.integer(forKey: sessionCountKey)
    }

    /// 导出为可读文本（设置页「数据管理」使用，也可用于本地排查）。
    func export() -> String {
        var lines: [String] = []
        lines.append("# 使用统计（仅本机，不含对话内容）")
        if let first = firstLaunchAt {
            lines.append("首次启动: \(AppFormatters.dateTimeMedium.string(from: first))")
        }
        lines.append("启动次数: \(sessionCount)")
        lines.append("")
        for event in TelemetryEvent.allCases {
            let value = count(of: event)
            guard value > 0 else { continue }
            lines.append("\(event.rawValue): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    /// 清空（用于「删除账号」）。
    func reset() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("telemetry.") {
            defaults.removeObject(forKey: key)
        }
    }
}
