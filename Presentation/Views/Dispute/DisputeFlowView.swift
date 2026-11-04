//
//  DisputeFlowView.swift
//  RelationshipCopilot
//
//  评理流程的主容器。**它只做状态渲染，不做业务判断**（业务在 DisputeFlowModel + Core）。
//
//  为什么状态要这么多：
//  同机双人流程的核心风险不是 AI 说错话，而是**流程漏气**。
//  `waitingForB` 这个状态存在的唯一目的，是强迫界面停一下、
//  把屏幕清空、把设备递过去。少了这一步，"各写各的"就变成"一人写完另一人瞄一眼"，
//  整个评理的前提（独立陈述）就没了。
//

import SwiftUI
import SwiftData

struct DisputeFlowView: View {

    @Bindable var disputeCase: DisputeCase
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var model: DisputeFlowModel?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ThemeManager.Colors.background.ignoresSafeArea()

            if let model {
                content(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // 生成完成与安全拦截各给一次反馈。
        //
        // 评理要等 8–20 秒（推理模型），期间只有一句「正在读你们写的东西…」。
        // 结果落定那一刻如果没有触感，用户经常以为还没好、反复点或直接退出去。
        .sensoryFeedback(feedbackFor(model), trigger: model?.outcome != nil)
        .task {
            if model == nil {
                let resolved = DisputeFlowModel(case: disputeCase)
                // 恢复「是否已沉淀为承诺」。少了这一步，重启后按钮会变回可点状态，
                // 用户重复点击会再生成一条内容完全相同的承诺。
                resolved.restoreAdoptedState(from: disputeCase)
                model = resolved
            }
        }
        .alert("出了点问题", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var navigationTitle: String {
        switch disputeCase.state {
        case .collectingA, .collectingB: return "写下来"
        case .waitingForB:               return "递过去"
        case .ready:                     return "可以看了"
        case .closed:                    return "第三方之见"
        case .blocked:                   return "已停止"
        }
    }

    @ViewBuilder
    private func content(model: DisputeFlowModel) -> some View {
        switch model.state {

        case .collectingA, .collectingB:
            collectingScreen(model: model)

        case .waitingForB:
            handoverScreen(model: model)

        case .ready:
            readyScreen(model: model)

        case .closed:
            resultScreen(model: model)

        case .blocked:
            blockedScreen(model: model)
        }
    }

    // MARK: 书写

    private func collectingScreen(model: DisputeFlowModel) -> some View {
        let author = model.currentAuthor ?? .a
        return ScrollView {
            TestimonyEditor(
                testimony: Binding(
                    get: { model.draft },
                    set: { model.draft = $0 }
                ),
                author: author,
                onSubmit: { submit(model: model) },
                footerNote: footerNote(for: author)
            )
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.vertical, ThemeManager.Spacing.lg)
            // 底部留白供浮动 tab bar：实测滚到底时余量 85pt（见
            // `test_result_bottom_clearance`）。早先以为这里被压住，
            // 其实是截图时页面还没滚到底。
            .padding(.bottom, ThemeManager.Spacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func footerNote(for author: DisputeParty) -> String {
        switch disputeCase.mode {
        case .sameDevice:
            return author == .a
                ? "写完后这份内容会锁住，交给对方时不会显示在屏幕上。对方写的时候，你也看不到他在写什么。"
                : "这是最后一份。写完就能一起看结果了。"
        case .solo:
            return "这里只有你一个人在写，所以待会儿给你的只会是你自己的梳理，不会有「谁对谁错」。"
        }
    }

    private func submit(model: DisputeFlowModel) {
        guard model.submit(to: disputeCase, context: modelContext) else {
            errorMessage = model.submissionHint ?? "提交失败"
            return
        }
        Telemetry.shared.track(.disputeSideSubmitted)
        // 单机模式只有一份，写完直接进生成
        if disputeCase.mode == .solo, disputeCase.state == .ready {
            Task { await generate(model: model) }
        }
    }

    // MARK: 交接设备

    //
    // 这一屏刻意是**空的**。它唯一的作用是让上一份内容从屏幕上消失。
    // 加任何"已收到"之类的动画都会延长暴露时间。

    private func handoverScreen(model: DisputeFlowModel) -> some View {
        VStack(spacing: ThemeManager.Spacing.xl) {
            Spacer()

            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(.largeTitle, design: .rounded))
                .foregroundStyle(ThemeManager.Colors.primary)
                .accessibilityHidden(true)

            VStack(spacing: ThemeManager.Spacing.md) {
                Text("把手机交给 TA")
                    .font(ThemeManager.Typography.title2)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text("你写的那一份已经收起来了，屏幕上不会显示。\nTA 写完之前，请不要在旁边看。")
                    .font(ThemeManager.Typography.callout)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
            }

            Spacer()

            VStack(spacing: ThemeManager.Spacing.md) {
                Button {
                    model.handOver(to: disputeCase, context: modelContext)
                } label: {
                    Text("TA 已经拿到了")
                        .font(ThemeManager.Typography.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(ThemeManager.Colors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                }
                .buttonStyle(PressableStyle())

                // 递错设备是真实会发生的事，必须给出退路
                Button {
                    model.returnToPreviousAuthor(disputeCase, context: modelContext)
                } label: {
                    Text("等会儿，我还要改")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.bottom, ThemeManager.Spacing.xxl)
        }
        .padding(.horizontal, ThemeManager.Spacing.lg)
    }

    // MARK: 待生成

    private func readyScreen(model: DisputeFlowModel) -> some View {
        VStack(spacing: ThemeManager.Spacing.xl) {
            Spacer()

            VStack(spacing: ThemeManager.Spacing.md) {
                Image(systemName: "text.bubble")
                    .font(.system(.largeTitle, design: .rounded))
                    .foregroundStyle(ThemeManager.Colors.primary)
                    .accessibilityHidden(true)

                Text("两份都写完了")
                    .font(ThemeManager.Typography.title2)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)

                Text(readyCopy)
                    .font(ThemeManager.Typography.callout)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(4)
            }

            Spacer()

            VStack(spacing: ThemeManager.Spacing.md) {
                if model.isGenerating {
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        ProgressView()
                        Text("正在读你们写的东西…")
                            .font(ThemeManager.Typography.callout)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                } else {
                    Button {
                        Task { await generate(model: model) }
                    } label: {
                        Text("一起看")
                            .font(ThemeManager.Typography.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(ThemeManager.Colors.primary)
                            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }

                if let error = model.error {
                    Text(error.errorDescription ?? "生成失败")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.bottom, ThemeManager.Spacing.xxl)
        }
        .padding(.horizontal, ThemeManager.Spacing.lg)
    }

    private var readyCopy: String {
        switch disputeCase.mode {
        case .sameDevice:
            return "现在请两个人一起看屏幕。\n接下来出现的内容不是判谁对谁错，是说清你们各自卡在哪。"
        case .solo:
            return "接下来只给你自己的梳理。\n因为你只写了一份，它不会假装知道对方怎么想。"
        }
    }

    /// 结果落定时的触感。
    ///
    /// 命中安全拦截用 `.warning` 而不是 `.error`：拦截是**正确行为**，
    /// 不是失败。用错误反馈会让用户以为"出错了、重试一下"，
    /// 而正确的下一步是去看求助信息。
    private func feedbackFor(_ model: DisputeFlowModel?) -> SensoryFeedback {
        guard let outcome = model?.outcome else { return .success }
        if outcome.isBlocked { return .warning }
        if outcome.isDegraded { return .warning }
        return .success
    }

    private func generate(model: DisputeFlowModel) async {
        await model.generate(for: disputeCase, context: modelContext)
        if let outcome = model.outcome {
            if outcome.isBlocked {
                Telemetry.shared.track(.disputeBlocked)
            } else if outcome.isDegraded {
                Telemetry.shared.track(.disputeDegraded)
            }
        }
    }

    // MARK: 结果

    private func resultScreen(model: DisputeFlowModel) -> some View {
        ScrollView {
            Group {
                if let outcome = model.outcome, let verdict = outcome.verdict {
                    DisputeVerdictView(
                        verdict: verdict,
                        // 降级提示必须由**数据**决定（`isDegradedVerdict` 已落盘），
                        // 不能只在本次会话的内存里。否则重启 App 后，
                        // 并列原话会被当成正常结论——把一次失败伪装成成功。
                        isDegraded: outcome.isDegraded,
                        onRegenerate: model.isGenerating ? nil : {
                            Task { await model.regenerate(for: disputeCase, context: modelContext) }
                        },
                        // 闭环：把第四段的具体动作沉淀成一条可打卡的承诺。
                        // 这是本产品相对参考产品（判决即终止）唯一的留存机制。
                        onAdoptAsPromise: {
                            model.adoptAsPromise(for: disputeCase, context: modelContext)
                        },
                        hasAdoptedPromise: model.createdPromise != nil
                    )
                } else {
                    Text("没有可显示的结果。")
                        .font(ThemeManager.Typography.body)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.vertical, ThemeManager.Spacing.lg)
            .padding(.bottom, ThemeManager.Spacing.xxl)
        }
    }

    // MARK: 安全拦截

    private func blockedScreen(model: DisputeFlowModel) -> some View {
        ScrollView {
            Group {
                if let guidance = model.safetyGuidance {
                    SafetyBlockedView(guidance: guidance)
                } else {
                    SafetyBlockedView(guidance: SafetyScreen.guidance(for: disputeCase.safetyConcerns))
                }
            }
            .padding(.horizontal, ThemeManager.Spacing.md)
            .padding(.vertical, ThemeManager.Spacing.lg)
            .padding(.bottom, ThemeManager.Spacing.xxl)
        }
    }
}
