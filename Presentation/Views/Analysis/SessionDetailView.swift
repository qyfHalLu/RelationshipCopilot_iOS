//
//  SessionDetailView.swift
//  RelationshipCopilot
//
//  一次记录的详情：转写文本 + AI 分析结果。
//
//  修复报告 C2 / A6：
//  - 原「分析结果」页（`RecordingView.swift` 里的 `AnalysisResultView`）里，
//    情绪分 65/45、沟通建议三条、情绪结论全部是硬编码常量，与实际录音无关。
//  - 原 `AnalysisResult` 把 `emotionalTrend` / `communicationQuality` 解析后丢弃，
//    且字段语义错位（communicationPatterns 存 strengths、keywords 存 improvements）。
//    现在通过语义访问器（`strengths` / `improvements` / `suggestions`）展示真实内容。
//  - 新增：无评分时明确说明「内容不足以判断」，而不是显示一个编造的数字。

import SwiftUI
import SwiftData

struct SessionDetailView: View {
    @Bindable var session: RecordingSession
    var showsDismiss: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var copied = false

    private var analysis: AnalysisResult? { session.analysisResult }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                header

                if let analysis, analysis.hasContent {
                    if let score = analysis.scoreValue {
                        scoreCard(score: score, summary: analysis.summary)
                    }

                    if let trend = analysis.emotionalTrend, !trend.isEmpty {
                        tagRow(title: "情绪走势", value: trend)
                    }
                    if let quality = analysis.communicationQuality, !quality.isEmpty {
                        tagRow(title: "沟通质量", value: quality)
                    }

                    if !analysis.strengths.isEmpty {
                        bulletCard(title: "做得好的地方", items: analysis.strengths,
                                   tint: ThemeManager.Colors.secondary, icon: "checkmark.circle.fill")
                    }
                    if !analysis.improvements.isEmpty {
                        bulletCard(title: "可以改进", items: analysis.improvements,
                                   tint: ThemeManager.Colors.accent, icon: "arrow.up.right.circle.fill")
                    }
                    if !analysis.suggestions.isEmpty {
                        bulletCard(title: "建议", items: analysis.suggestions,
                                   tint: ThemeManager.Colors.primary, icon: "lightbulb.fill")
                    }
                } else if session.state == .completed {
                    unavailableCard
                }

                transcriptionCard

                if let profile = session.profile {
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        Image(systemName: "person.fill")
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                        Text("关联：\(profile.name) · \(profile.relationship.displayName)")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                }

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除这次记录", systemImage: "trash")
                        .font(ThemeManager.Typography.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ThemeManager.Spacing.sm)
                }
                .buttonStyle(.bordered)
            }
            .padding(ThemeManager.Spacing.md)
        }
        .background(ThemeManager.Colors.background)
        .navigationTitle(session.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("删除这次记录？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteSession() }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    // MARK: 组件

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppFormatters.dateTimeMedium.string(from: session.startedAt))
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            if let duration = session.duration {
                Text("时长 \(AppFormatters.duration(duration))")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
        }
    }

    // MARK: 单次对话的评分
    //
    // 这里的 `score` 来自模型真的读过这段对话之后给出的判断
    // （`AnalysisResult.scoreValue`），不是被删掉的 `70 + intimacy * 3`。
    // 但措辞必须跟着改：它评价的是**这一次对话**，不是「你们的关系」。
    // 原来写「这次对话的关系健康度 85 分」是把两件事混成了一个名词。

    private func scoreCard(score: Int, summary: String?) -> some View {
        let level = Self.level(for: score)
        return VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("\(score)")
                    .font(ThemeManager.Typography.scoreDisplay)
                    .foregroundStyle(level.tint)
                Text("/100")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                Spacer(minLength: ThemeManager.Spacing.sm)
                Text(level.title)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(level.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(level.tint.opacity(0.12))
                    .clipShape(Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("这次对话 \(score) 分，满分 100，\(level.title)")

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(ThemeManager.Typography.callout)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("这个分数只看这一段对话，代表不了你们的关系。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: ThemeManager.Spacing.md)
    }

    /// 单次对话的评级。与已删除的关系健康度档位不同：
    /// 那个 `Band` 有 `critical` 而实际分数下限是 70，红色永不出现；
    /// 这里的分数真的可以是 0–100，四档都能到达。
    private struct ScoreLevel {
        let title: String
        let tint: Color

        static func forScore(_ score: Int) -> ScoreLevel {
            switch score {
            case ..<40:   return ScoreLevel(title: "很紧张", tint: ThemeManager.Colors.danger)
            case 40..<65: return ScoreLevel(title: "有点紧", tint: ThemeManager.Colors.accent)
            case 65..<85: return ScoreLevel(title: "还行", tint: ThemeManager.Colors.secondary)
            default:      return ScoreLevel(title: "比较顺", tint: ThemeManager.Colors.primary)
            }
        }
    }

    private static func level(for score: Int) -> ScoreLevel {
        ScoreLevel.forScore(score)
    }

    private func tagRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
            Text(value)
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
            Spacer()
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
    }

    private func bulletCard(title: String, items: [String], tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text(title)
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
                    Image(systemName: icon)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(tint)
                        .padding(.top, 3)
                    Text(item)
                        .font(ThemeManager.Typography.callout)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: ThemeManager.Spacing.md)
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Label("这次没有生成分析", systemImage: "info.circle")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
            Text("可能是没有识别到有效对话内容，或分析服务当时不可用。文字记录已保留，可稍后重试。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: ThemeManager.Spacing.md)
    }

    private var transcriptionCard: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack {
                Text("对话记录")
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                Spacer()
                if let text = session.transcription, !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(ThemeManager.Typography.caption)
                    }
                }
            }

            let text = session.transcription ?? ""
            Text(text.isEmpty ? "没有识别到文字内容" : text)
                .font(ThemeManager.Typography.callout)
                .foregroundStyle(text.isEmpty
                                 ? ThemeManager.Colors.textSecondary
                                 : ThemeManager.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: ThemeManager.Spacing.md)
    }

    // MARK: 动作

    private func deleteSession() {
        // 删除会话同时删除关联的音频（若有）
        if let path = session.audioFileURL {
            RecordingService.removeFile(at: URL(fileURLWithPath: path))
        }
        modelContext.delete(session)
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.error("Delete session failed: \(error.localizedDescription, privacy: .public)")
        }
        if showsDismiss { dismiss() }
    }
}
