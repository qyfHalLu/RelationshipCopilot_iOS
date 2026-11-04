//
//  DisputeVerdictView.swift
//  RelationshipCopilot
//
//  「第三方之见」的结果渲染。**这是整个产品的交付物**，四段缺一不可。
//
//  排版原则：
//   ① 四段平级纵向排列，**不做卡片堆叠**。
//      用卡片包每一段会让读者以为它们是四个可以"翻过去"的独立结论，
//      而这四段是一条链：重命名 → 各自被听见 → 共同卡点 → 分流。
//      链断了，结论就变成可挑选的（"我只认同第三段"）。
//   ② needA / needB 用**完全相同的容器样式与相同的正文字号**。
//      任何视觉差异（一侧加粗、一侧缩进、一侧换色）都是偏袒。
//   ③ 底部固定一行「你可以不认同」——这不是免责，是设计上的可退出权。
//

import SwiftUI

struct DisputeVerdictView: View {

    let verdict: DisputeVerdict
    /// 是否显示降级提示（`.fallback` 时）。
    let isDegraded: Bool
    /// 重新生成。
    let onRegenerate: (() -> Void)?
    /// 把第四段的动作沉淀成一条可打卡的承诺。
    /// 为 nil 或 `verdict.canBecomePromise == false` 时不显示按钮。
    var onAdoptAsPromise: (() -> Void)?
    /// 已经沉淀过（用于把按钮改成"已添加"并禁用）。
    var hasAdoptedPromise: Bool = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.xl) {

            if isDegraded {
                degradedNotice
            }

            reframeSection
            needsSection
            stuckSection
            closingSection
            exitLine
        }
    }

    // MARK: 降级提示

    private var degradedNotice: some View {
        HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(ThemeManager.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("这次没能形成真正的第三方之见")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                Text("下面只是把你们各自写的原话并列出来，没有做任何推断。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ThemeManager.Spacing.md)
        .background(ThemeManager.Colors.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: ① 重命名争点

    private var reframeSection: some View {
        section(number: "①", title: "你们其实在争两件事") {
            Text(verdict.reframe)
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
    }

    // MARK: ② 双方想被听见

    private var needsSection: some View {
        section(number: "②", title: "各自想被听见的一句") {
            VStack(spacing: ThemeManager.Spacing.md) {
                needRow(label: "一方", text: verdict.needA)
                needRow(label: "另一方", text: verdict.needB)
            }

            if !verdict.symmetry.passed {
                // 正常情况下解析层已拦下不对称结果，走到这里说明是通过其他路径构造的。
                Text("两段长度不一致，这是生成的问题，不是谁更重要。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 两侧共用同一个渲染函数。**参数化的是内容，不是样式** ——
    /// 一旦这里出现 `if isA { ... } else { ... }` 的样式分支，中立就破了。
    private func needRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
            Text(text)
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ThemeManager.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeManager.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: ③ 共同卡点

    private var stuckSection: some View {
        section(number: "③", title: "你们卡在哪") {
            Text(verdict.stuckPoint)
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
        }
    }

    // MARK: ④ 分流结论

    private var closingSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {

            // 分流标签。这一句是**产品最核心的差异化**：
            // 永久型问题不该给"解决方案"，给了注定失败。
            HStack(spacing: ThemeManager.Spacing.sm) {
                Image(systemName: verdict.solvability == .solvable
                      ? "wrench.and.screwdriver.fill"
                      : "arrow.triangle.2.circlepath")
                    .font(ThemeManager.Typography.caption)
                Text(verdict.solvability.displayName)
                    .font(ThemeManager.Typography.subheadline.weight(.semibold))
            }
            .foregroundStyle(verdict.solvability == .solvable
                             ? ThemeManager.Colors.primary
                             : ThemeManager.Colors.accent1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                (verdict.solvability == .solvable
                 ? ThemeManager.Colors.primary
                 : ThemeManager.Colors.accent1).opacity(0.12)
            )
            .clipShape(Capsule())
            .accessibilityElement(children: .combine)

            Text(verdict.solvability.explanation)
                .font(ThemeManager.Typography.footnote)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            if let closing = verdict.closing {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                    Text(verdict.solvability == .solvable ? "今晚可以做的一件事" : "可以长期这么放着的说法")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)

                    Text(closing)
                        .font(ThemeManager.Typography.body)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)

                    // 「沉淀为承诺」放在第四段内部，而不是页面底部另起一块。
                    //
                    // 它不是一个独立功能，是**这一段动作的延伸**：
                    // 动作说的是"这周找一次，先说一句那一定很难受"，
                    // 这条按钮只是把它变成明天还记得的东西。
                    // 放到页面底部会变成"又一个按钮"，用户不会认为两者是一件事。
                    if let onAdoptAsPromise, verdict.canBecomePromise {
                        adoptButton(action: onAdoptAsPromise)
                    }
                }
                .padding(ThemeManager.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (verdict.solvability == .solvable
                     ? ThemeManager.Colors.primary
                     : ThemeManager.Colors.accent1).opacity(0.07)
                )
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            }
        }
    }

    // MARK: 沉淀为承诺

    /// 把第四段的动作变成承诺。
    ///
    /// 只对可解决型出现（`verdict.canBecomePromise`）。永久型的第四段是共存说法，
    /// 不是一次性行为，做成打卡项会把相处方式降格成 KPI —— 见 Core 层注释。
    private func adoptButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: ThemeManager.Spacing.sm) {
                Image(systemName: hasAdoptedPromise ? "checkmark.circle.fill" : "plus.circle")
                    .font(ThemeManager.Typography.subheadline)
                Text(hasAdoptedPromise ? "已加进承诺" : "记成一条承诺，之后可以打卡")
                    .font(ThemeManager.Typography.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(hasAdoptedPromise
                             ? ThemeManager.Colors.textSecondary
                             : ThemeManager.Colors.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.top, ThemeManager.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(hasAdoptedPromise)
        .accessibilityHint(hasAdoptedPromise
                           ? "已经添加过，无需重复添加"
                           : "把上面这条动作存进承诺，之后每天可以打勾")
    }

    // MARK: 退出权

    private var exitLine: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Divider()
                .background(ThemeManager.Colors.border)

            Text("以上是一个旁观者能看到的。你可以不认同——你们比任何第三方都更了解这段关系。")
                .font(ThemeManager.Typography.footnote)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            // 带走：复制 / 分享。
            //
            // 放在「退出权」这一块、而不是页面顶部：它不是要引导用户去传播，
            // 而是提供一条退路 —— 想留着或想让对方也看看时，不用截图。
            //
            // 尤其第四段那句「今晚可以做的一件事」，是本产品唯一要用户"去做"的东西，
            // 不能复制就等于只能靠记忆。
            takeAwayRow

            if let onRegenerate {
                Button(action: onRegenerate) {
                    Label("重新生成一次", systemImage: "arrow.clockwise")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: 带走

    private var takeAwayRow: some View {
        HStack(spacing: ThemeManager.Spacing.sm) {
            Button {
                UIPasteboard.general.string = verdict.shareText
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制全文",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(copied ? ThemeManager.Colors.secondary : ThemeManager.Colors.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint("把四段完整复制成文字，可以直接粘贴给对方")

            Divider()
                .frame(height: 20)

            ShareLink(item: verdict.shareText) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint("通过系统分享面板发送这段文字")
        }
        .padding(.top, ThemeManager.Spacing.xs)
    }

    // MARK: 段落骨架

    @ViewBuilder
    private func section<Content: View>(
        number: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: ThemeManager.Spacing.sm) {
                Text(number)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.primary)
                Text(title)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }
}

// MARK: - 安全拦截页

/// 命中安全风险时的页面。**不给评理、不给建议、不给对错**，只给求助路径。
struct SafetyBlockedView: View {

    let guidance: SafetyGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {

            HStack(spacing: ThemeManager.Spacing.md) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(ThemeManager.Colors.danger)
                Text(guidance.title)
                    .font(ThemeManager.Typography.title3)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(guidance.body)
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)

            Text(guidance.actionLine)
                .font(ThemeManager.Typography.callout)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .padding(ThemeManager.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemeManager.Colors.danger.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))

            Text("这件事的原文只有你自己看得到，我们没有把它发给任何模型。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
