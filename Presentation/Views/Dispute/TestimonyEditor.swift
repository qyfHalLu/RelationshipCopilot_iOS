//
//  TestimonyEditor.swift
//  RelationshipCopilot
//
//  证词填写界面：四问，逐题作答。
//
//  设计要点（全部来自界面审查的实测结论，不是偏好）：
//   ① **不用 HStack 固定横排 + minimumScaleFactor 缩字号**。
//      上一轮 accessibility-XXXL 下四宫格被压成纯色方块，根因就是这个组合。
//      这里每题独立成块、纵向排列，标题允许折行（`fixedSize` 竖向）。
//   ② 输入区用 `TextEditor` 而非 `TextField(axis: .vertical)`：
//      四问每题 200 字，需要真正可滚动的多行区域。
//   ③ **按钮高度 ≥ 44pt**（首页打卡 chip 实测只有 24–26pt，是硬缺陷）。
//   ④ 每题标题用 `.headline`，追问用 `.footnote` + `textSecondary`，
//      层次靠字号与颜色，不靠色块堆叠。
//

import SwiftUI

struct TestimonyEditor: View {

    @Binding var testimony: DisputeTestimony
    /// 当前作者，用于顶部提示。
    let author: DisputeParty
    /// 提交回调。
    let onSubmit: () -> Void
    /// 底部说明（同机模式要显示"对方看不到你写的"；单机模式显示别的）。
    let footerNote: String

    @FocusState private var focused: TestimonyQuestion?

    /// 题号徽章直径**随字号一起缩放**。
    ///
    /// 历史缺陷（XXXL 截图实证）：这里原本硬编码 `.frame(width: 20, height: 20)`，
    /// 而数字用的是 `.caption`——一个会跟随动态字体放大的语义字号。
    /// XXXL 下 caption 已接近 28pt，数字溢出 20pt 的紫色圆；
    /// 数字又是白色，一旦离开紫圆就落在浅色背景上彻底看不见，
    /// 屏幕上只剩一个被容器左边缘切掉一半的紫色小半圆，题号完全不可读。
    ///
    /// 根因是"框是常量、字是变量"——两者必须同源缩放，否则迟早脱节。
    @ScaledMetric(relativeTo: .caption) private var badgeDiameter: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {

            header

            ForEach(TestimonyQuestion.allCases) { question in
                questionBlock(question)
            }

            submitButton

            if !footerNote.isEmpty {
                Text(footerNote)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("\(author.displayName)这一份")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: ThemeManager.Spacing.sm) {
                Text("\(testimony.answeredCount) / \(TestimonyQuestion.allCases.count)")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .monospacedDigit()

                ProgressView(value: Double(testimony.answeredCount),
                             total: Double(TestimonyQuestion.allCases.count))
                    .tint(ThemeManager.Colors.primary)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("已回答 \(testimony.answeredCount) 题，共 \(TestimonyQuestion.allCases.count) 题")
        }
    }

    // MARK: 单题

    private func questionBlock(_ question: TestimonyQuestion) -> some View {
        let text = testimony.answer(for: question)
        let remaining = TestimonyQuestion.characterLimit - text.count
        let isFocused = focused == question

        return VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {

            // 题号 + 题干。题干允许折行，不缩字号。
            //
            // 徽章用 `.firstTextBaseline` 对齐后，XXXL 下 besar 的标题会把它往下带；
            // 改为固定到顶部对齐，徽章与题干首行同一水平线更稳。
            // 徽章自身用 `fixedSize`：既不让 HStack 压缩它，也不让它被父容器裁掉。
            HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
                Text("\(question.rawValue + 1)")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(.white)
                    .frame(width: badgeDiameter, height: badgeDiameter)
                    .background(ThemeManager.Colors.primary)
                    .clipShape(Circle())
                    .fixedSize()
                    .accessibilityHidden(true)

                Text(question.title)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(question.hint)
                .font(ThemeManager.Typography.footnote)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("在这里写…")
                        .font(ThemeManager.Typography.body)
                        .foregroundStyle(ThemeManager.Colors.textSecondary.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                TextEditor(text: Binding(
                    get: { testimony.answer(for: question) },
                    set: { testimony.setAnswer($0, for: question) }
                ))
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(minHeight: 96)
                .focused($focused, equals: question)
                .accessibilityLabel(question.title)
                .accessibilityHint(question.hint)
            }
            .background(ThemeManager.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous)
                    .strokeBorder(
                        isFocused ? ThemeManager.Colors.primary : ThemeManager.Colors.border,
                        lineWidth: isFocused ? 2 : 1
                    )
            )

            // 剩余字数。到 20 字以内才提示，避免平时刷存在感。
            // 语音输入 + 字数提示。
            //
            // 每道题上限 200 字，四道题合计最多 800 字。让人用键盘敲完，
            // 大多数人会在第二题就放弃，最后交上来的都是"就那样吧"这种
            // 三五个字的敷衍答案 —— 而评理的质量完全取决于证词的具体程度。
            // 说话比打字快得多，这是整套流程能不能收到有效输入的关键。
            HStack(spacing: ThemeManager.Spacing.sm) {
                VoiceInputButton(
                    text: Binding(
                        get: { testimony.answer(for: question) },
                        set: { testimony.setAnswer($0, for: question) }
                    ),
                    subject: question.title
                )

                if remaining <= 20 {
                    Text(remaining > 0 ? "还可以写 \(remaining) 字" : "已到上限")
                        .font(ThemeManager.Typography.caption2)
                        .foregroundStyle(remaining > 0 ? ThemeManager.Colors.textSecondary : ThemeManager.Colors.accent)
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 提交

    private var submitButton: some View {
        Button(action: onSubmit) {
            Text(canSubmit ? "写完了" : "还有没写的")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(canSubmit ? .white : ThemeManager.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                // 44pt 是硬底线，不是"差不多"
                .frame(minHeight: 52)
                .background(canSubmit ? ThemeManager.Colors.primary : ThemeManager.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(!canSubmit)
        .accessibilityHint(canSubmit ? "提交后内容将无法修改" : "请先回答全部四个问题")
    }

    private var canSubmit: Bool { testimony.isComplete }
}
