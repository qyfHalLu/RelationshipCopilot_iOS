//
//  MetricsReporter.swift
//  RelationshipCopilot
//
//  修复报告 E5 / R5：项目没有任何崩溃与性能观测，导致"发布后才知道坏在哪"。
//
//  这里接入 Apple 自带的 MetricKit：系统会每天回传一次崩溃、卡顿、启动耗时、
//  内存峰值等聚合数据，无需第三方 SDK、无需 ATT 授权、不进隐私清单的"跟踪"类别。
//
//  数据先落本地（可导出），后续接后端时只要在 `store` 之后加一次上传即可。
//
//  注意：模拟器不会产生 MetricKit 数据，只有在真机 + TestFlight/正式包上才会回传，
//  因此本文件的正确性靠编译与协议实现保证，运行时效果需真机验证（见交付报告「剩余问题」）。
//

import Foundation
import MetricKit

/// 一条指标摘要，字段保持最小集，便于后续上报。
struct MetricSnapshot: Codable, Sendable, Equatable {
    let recordedAt: Date
    let kind: String          // crash / hang / launch / memory / disk
    let summary: String
}

@MainActor
final class MetricsReporter: NSObject {

    static let shared = MetricsReporter()

    private let defaults: UserDefaults
    private let storageKey = "metrics.snapshots"
    private let maxSnapshots = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// 在 App 启动时调用一次，注册为 MetricKit 订阅者。
    func start() {
        MXMetricManager.shared.add(self)
        AppLog.app.info("MetricKit subscriber registered")
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: 本地存储

    private(set) var snapshots: [MetricSnapshot] {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([MetricSnapshot].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            let trimmed = Array(newValue.suffix(maxSnapshots))
            if let data = try? JSONEncoder().encode(trimmed) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    func append(_ snapshot: MetricSnapshot) {
        var current = snapshots
        current.append(snapshot)
        snapshots = current
    }

    func export() -> String {
        let items = snapshots
        guard !items.isEmpty else { return "# 暂无系统回传的性能数据（模拟器不会产生）" }
        var lines = ["# 性能与稳定性快照（由 MetricKit 回传）"]
        let formatter = AppFormatters.dateTimeMedium
        for item in items.reversed() {
            lines.append("\(formatter.string(from: item.recordedAt)) [\(item.kind)] \(item.summary)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - MXMetricManagerSubscriber

extension MetricsReporter: MXMetricManagerSubscriber {

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let summaries = payloads.compactMap(Self.summarize(metric:))
        guard !summaries.isEmpty else { return }
        Task { @MainActor in
            summaries.forEach { self.append($0) }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let summaries = payloads.compactMap(Self.summarize(diagnostic:))
        guard !summaries.isEmpty else { return }
        Task { @MainActor in
            summaries.forEach { self.append($0) }
        }
    }

    // MARK: 摘要

    private nonisolated static func summarize(metric payload: MXMetricPayload) -> MetricSnapshot? {
        var parts: [String] = []

        // 只使用确定存在的标量指标。直方图类（启动耗时等）需要遍历 MXHistogram 的桶，
        // 各系统版本 API 形态有差异，这里不做猜测，避免上线后才发现取不到值。
        if let memory = payload.memoryMetrics {
            let megabytes = memory.peakMemoryUsage.converted(to: .megabytes).value
            parts.append(String(format: "峰值内存 %.1f MB", megabytes))
        }

        guard !parts.isEmpty else { return nil }
        return MetricSnapshot(recordedAt: Date(), kind: "metric", summary: parts.joined(separator: " · "))
    }

    private nonisolated static func summarize(diagnostic payload: MXDiagnosticPayload) -> MetricSnapshot? {
        var parts: [String] = []
        if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
            parts.append("崩溃 \(crashes.count) 次")
        }
        if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
            parts.append("卡死 \(hangs.count) 次")
        }
        if let cpu = payload.cpuExceptionDiagnostics, !cpu.isEmpty {
            parts.append("CPU 异常 \(cpu.count) 次")
        }
        guard !parts.isEmpty else { return nil }
        return MetricSnapshot(recordedAt: Date(), kind: "diagnostic", summary: parts.joined(separator: " · "))
    }
}
