import SwiftUI
import SwiftData

// MARK: - 分析报告
//
// 修复报告 C2 / B6 / C8：
//  - C2（P0）：原 `AnalysisOverviewCard` 显示「12 次分析 / +15% 关系改善 / 48 获得建议」，
//    全部是硬编码常量；更糟的是同一个页面下方还显示「暂无分析记录」，自相矛盾。
//    这类"真数据与假数据混排"是审核 2.3.1 的典型靶子。现在所有数字均由 `@Query` 计算得出，
//    无数据时走统一空状态。
//  - B6：原 `HistoryItem.formattedDate` 每行每次渲染都新建 `DateFormatter`，现改用 `AppFormatters`。
//  - C8：空状态补主 CTA。
//  - 新增：支持删除单条记录（原实现没有任何删除入口，隐私类 App 不可接受）。

struct AnalysisView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]

    private var analyzedSessions: [RecordingSession] {
        sessions.filter { $0.analysisResult?.hasContent == true }
    }

    private var thisMonthSessions: [RecordingSession] {
        let calendar = Calendar.current
        let now = Date()
        return sessions.filter {
            calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month)
        }
    }

    /// 已分析记录的平均分。
    ///
    /// 注意与「已删除的关系健康度」区分：这里的分数来自
    /// `AnalysisResult.scoreValue` —— 模型真的读了对话内容之后给出的判断，
    /// 并且模型可以拒绝给分（`emotionScore` 为 nil 时不参与平均）。
    /// 被删掉的那个是 `70 + intimacy * 3`，用户自己拖滑块拖出来的。
    /// 两者长得像，性质完全不同：一个是测量，一个是回声。
    private var averageScore: Int? {
        let scores = analyzedSessions.compactMap { $0.analysisResult?.scoreValue }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ThemeManager.Spacing.lg) {
                if sessions.isEmpty {
                    EmptyAnalysisView { router.switchTo(.home) }
                } else {
                    overviewCard
                    HistorySection(sessions: sessions, onDelete: delete)
                }
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.vertical, ThemeManager.Spacing.lg)
        }
        .background(ThemeManager.Colors.background)
        .navigationTitle("分析报告")
        .navigationBarTitleDisplayMode(.large)
    }

    // 所有数字都是真实计算值；无数据时显示「—」而不是编造
    private var overviewCard: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            Text("本月概览")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: ThemeManager.Spacing.md) {
                OverviewStat(
                    icon: "waveform",
                    value: "\(thisMonthSessions.count)",
                    label: "本月记录",
                    tint: ThemeManager.Colors.primary
                )
                OverviewStat(
                    icon: "checkmark.seal",
                    value: "\(analyzedSessions.count)",
                    label: "已分析",
                    tint: ThemeManager.Colors.secondary
                )
                OverviewStat(
                    icon: "heart.text.square",
                    value: averageScore.map(String.init) ?? "—",
                    label: "平均分",
                    tint: ThemeManager.Colors.accent
                )
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .surfaceCard()
    }

    private func delete(_ session: RecordingSession) {
        if let path = session.audioFileURL {
            RecordingService.removeFile(at: URL(fileURLWithPath: path))
        }
        modelContext.delete(session)
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 概览统计

struct OverviewStat: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(value)
                .font(ThemeManager.Typography.title2)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }
}

// MARK: - 历史记录

struct HistorySection: View {
    let sessions: [RecordingSession]
    let onDelete: (RecordingSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("历史记录")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            LazyVStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(sessions) { session in
                    HistoryRow(session: session)
                        .contextMenu {
                            Button(role: .destructive) {
                                onDelete(session)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let session: RecordingSession

    private var statusText: String { session.state.displayName }
    private var statusTint: Color {
        switch session.state {
        case .analyzed:  return ThemeManager.Colors.secondary
        case .completed: return ThemeManager.Colors.accent
        case .recording: return ThemeManager.Colors.primary
        }
    }

    var body: some View {
        NavigationLink {
            SessionDetailView(session: session)
        } label: {
            HStack(spacing: ThemeManager.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: iconName)
                        .font(.body)
                        .foregroundStyle(iconTint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.kind.displayName)
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)

                    Text(AppFormatters.dateTimeMedium.string(from: session.createdAt))
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)

                    if let summary = session.analysisResult?.summary, !summary.isEmpty {
                        Text(summary)
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let score = session.analysisResult?.scoreValue {
                        Text("\(score)")
                            .font(ThemeManager.Typography.headline)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                    }
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusTint.opacity(0.12))
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
            .padding(ThemeManager.Spacing.md)
            .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        switch session.kind {
        case .conflict:     return "exclamationmark.bubble.fill"
        case .conversation: return "bubble.left.fill"
        case .other:        return "waveform"
        }
    }

    private var iconTint: Color {
        switch session.kind {
        case .conflict:     return ThemeManager.Colors.accent
        case .conversation: return ThemeManager.Colors.primary
        case .other:        return ThemeManager.Colors.accent3
        }
    }
}

// MARK: - 空状态

struct EmptyAnalysisView: View {
    let onStartRecording: () -> Void

    var body: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(.largeTitle, design: .rounded))
                .foregroundStyle(ThemeManager.Colors.textSecondary.opacity(0.6))

            Text("还没有分析记录")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text("在「记录」里录一段对话，分析结果会自动出现在这里。")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: onStartRecording) {
                Label("去记录", systemImage: "mic.fill")
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ThemeManager.Spacing.sm)
                    .background(ThemeManager.Colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(ThemeManager.Spacing.xl)
        .surfaceCard()
    }
}
