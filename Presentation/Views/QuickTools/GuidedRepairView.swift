//
//  GuidedRepairView.swift
//  RelationshipCopilot
//
//  「道歉准备」的引导式界面。
//
//  ## 这个页面和别的工具最大的不同
//
//  它没有「生成」按钮。
//
//  整条流程不产生任何一句可以复制的话 —— 最后那四格由用户自己填。
//  我们做的事只有三件：提问、校验、指出逃避。
//
//  设计文档里那句话是这么写的：
//  「现在的产品在替用户说；改完之后，产品只做一件事：
//    让用户看见自己那句话里缺了什么，然后逼他自己补。」
//

import SwiftUI
import UIKit

// MARK: - 入口分发

/// 快速工具的目标页。
///
/// 道歉准备走引导流程，其余两个仍走"输入 → 生成"。
/// 分在这里而不是塞进 `QuickToolDetailView`：那个视图只该做一件事。
struct QuickToolDestination: View {
    let kind: QuickToolKind

    var body: some View {
        switch kind {
        case .apology:
            GuidedRepairView()
        case .conflict, .phrase:
            QuickToolDetailView(tool: kind)
        }
    }
}

// MARK: - 引导流程

struct GuidedRepairView: View {
    @State private var draft: RepairDraft
    @State private var step: RepairStep
    @State private var showTheory = false
    @State private var copied = false

    @FocusState private var focused: Bool

    init() {
        _draft = State(initialValue: Self.initial().draft)
        _step = State(initialValue: Self.initial().step)
    }

    private static func initial() -> (draft: RepairDraft, step: RepairStep) {
        #if DEBUG
        if let prefill = UITestSupport.repairPrefill {
            return debugSample(prefill)
        }
        #endif
        let saved = RepairDraftStore.load()
        // 恢复现场：如果上次答过安全闸门且是"不害怕"，回到当时那一步；
        // 答过"害怕"就停在资源页 —— 不能让用户重启后被推进道歉流程。
        guard let saved, saved.fearedReaction == false else {
            return (saved ?? RepairDraft(), .safety)
        }
        return (saved, RepairStep(rawValue: saved.stepIndex) ?? .action)
    }

    #if DEBUG
    private static func debugSample(_ name: String) -> (draft: RepairDraft, step: RepairStep) {
        var draft = RepairDraft()
        switch name {
        case "action-vague":
            draft.action = "我态度不好"
            return (draft, .action)
        case "losses-empty":
            return (draft, .losses)
        case "losses-abstract":
            draft.setLoss("TA 很不开心，饭也没吃完就回房了", for: .dignity)
            return (draft, .losses)
        case "losses-filled":
            draft.setLoss("TA 妈妈在客厅，TA 被我那句话堵得没再说下去", for: .dignity)
            return (draft, .losses)
        case "skeleton":
            draft.skeleton = [
                "答应了六点去接 TA，结果跟同事去喝酒了",
                "白等了三个多小时",
                "我把它排在了后面",
                "这周三把饭补上"
            ]
            return (draft, .skeleton)
        default:
            return (draft, .safety)
        }
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                if draft.fearedReaction == true {
                    safetyResources
                } else if step == .safety {
                    safetyGate
                } else {
                    progressHeader
                    VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                        Text(step.prompt)
                            .font(ThemeManager.Typography.body)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(4)

                        if let hint = step.hint {
                            Text(hint)
                                .font(ThemeManager.Typography.caption)
                                .foregroundStyle(ThemeManager.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    stepContent

                    if let theory = step.theory {
                        theoryCard(theory)
                    }

                    navigation
                }
            }
            .padding(ThemeManager.Spacing.md)
        }
        .background(ThemeManager.Colors.background)
        .navigationTitle("道歉准备")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: step) { _, newValue in
            draft.stepIndex = newValue.rawValue
            showTheory = false
        }
        .onChange(of: draft) { _, newValue in
            RepairDraftStore.save(newValue)
        }
    }

    // MARK: 进度

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("第 \(step.ordinal) 步 · 共 \(RepairStep.total) 步")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                Spacer()
                Button {
                    reset()
                } label: {
                    Text("重来")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重新开始这次道歉准备")
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ThemeManager.Colors.surfaceElevated)
                    Capsule()
                        .fill(ThemeManager.Colors.primary)
                        .frame(width: proxy.size.width * CGFloat(step.ordinal) / CGFloat(RepairStep.total))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
    }

    // MARK: 安全闸门

    private var safetyGate: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("你现在是否害怕告诉对方你的真实想法？")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("怕他发火、怕他报复、怕他冷战好几天。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            VStack(spacing: ThemeManager.Spacing.sm) {
                primaryButton("不是") {
                    draft.fearedReaction = false
                    focused = true
                    withAnimation(.smooth(duration: 0.2)) { step = .action }
                }

                Button {
                    draft.fearedReaction = true
                    Telemetry.shared.track(.quickToolOpened)
                } label: {
                    Text("是，有一点")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(ThemeManager.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.lg)
    }

    /// 害怕对方反应时给的页面。
    ///
    /// **不提供道歉训练**。理由是伦理性的：
    /// 「如何更有效地道歉」这套技术在权力不对等的关系里，
    /// 会被反过来用于维持控制 —— 让人更会说服对方原谅自己。
    /// 产品不该服务这个场景。
    private var safetyResources: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Label("先别急着道歉", systemImage: "hand.raised.fill")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text("如果你在害怕对方的反应，那么「把道歉说得更好」帮不上忙 —— 反而可能让你更难开口。")
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)

            Text("这不是你需要更努力沟通的问题。你不需要现在做任何决定。")
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("如果情况紧急，可以联系：")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                Text("全国妇联妇女维权热线 12338")
                    .font(ThemeManager.Typography.callout)
                    .foregroundStyle(ThemeManager.Colors.primary)
                Text("（如果涉及人身安全，请直接拨打 110）")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }

            Button {
                draft.fearedReaction = nil
                withAnimation { step = .safety }
            } label: {
                Text("我理解，回到上一个问题")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.lg)
    }

    // MARK: 各步内容

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .safety:
            EmptyView()

        case .action:
            editor($draft.action, placeholder: "六点我去接 TA，结果……")
            issueList(RepairLinter.lintAction(draft.action))

        case .explanation:
            editor($draft.explanation, placeholder: "那天我……", minHeight: 96)
            issueList(RepairLinter.lintExplanation(draft.explanation))
            note("有时候最有尊严的说法是：没有借口。不是「我太忙了」，就是「我把它排在了后面」。")

        case .losses:
            lossesStep

        case .perspective:
            Text("我猜 TA 当时最在意的是")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
            editor($draft.guess, placeholder: "我猜……", minHeight: 80)
            issueList(RepairLinter.lintGuess(draft.guess))

            Text("把它变成一句可以去问的话")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .padding(.top, ThemeManager.Spacing.sm)
            editor($draft.question, placeholder: "那天我说那句话的时候，你是什么感觉？", minHeight: 80)
            issueList(RepairLinter.lintQuestion(draft.question))

        case .repairAction:
            fieldLabel("什么时候")
            editor($draft.repairWhen, placeholder: "这周三晚饭后", minHeight: 60)
            fieldLabel("做什么")
                .padding(.top, ThemeManager.Spacing.sm)
            editor($draft.repairWhat, placeholder: "把那天的饭补上", minHeight: 60)
            fieldLabel("如果他说「不用了」，你怎么接")
                .padding(.top, ThemeManager.Spacing.sm)
            editor($draft.ifRefused, placeholder: "那我就先不打扰，过两天再问一次", minHeight: 60)
            issueList(RepairLinter.lintRepairAction(
                time: draft.repairWhen,
                action: draft.repairWhat,
                ifRefused: draft.ifRefused
            ))

        case .skeleton:
            skeletonStep
        }
    }

    // MARK: Step 3 · 七格

    private var lossesStep: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            ForEach(LossCell.allCases) { cell in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(cell.title)
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                        if cell.isPriority {
                            Text("权重最高")
                                .font(.caption2)
                                .foregroundStyle(ThemeManager.Colors.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ThemeManager.Colors.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                        // 麦克风放在标题行，不占输入框宽度。
                        //
                        // 这一屏七个格子，每格都要求「具体到能看见」——
                        // 恰恰是全流程最需要说话、最不想打字的地方。
                        // 之前这里写的是 showsVoice: false，理由是"太挤"：
                        // 排版上的省事，代价是把最需要语音的那一屏关掉了。
                        VoiceInputButton(
                            text: Binding(
                                get: { draft.loss(cell) },
                                set: { draft.setLoss($0, for: cell) }
                            ),
                            subject: cell.title,
                            compact: true
                        )
                    }

                    Text(cell.prompt)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)

                    editor(
                        Binding(
                            get: { draft.loss(cell) },
                            set: { draft.setLoss($0, for: cell) }
                        ),
                        placeholder: cell.criterion,
                        minHeight: 66,
                        showsVoice: false
                    )

                    let issues = RepairLinter.lintLoss(draft.loss(cell))
                    issueList(issues)
                }
            }

            if !RepairLinter.hasSubstantiveLoss(draft.lossDict) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("写不出来很正常。这正是你还不了解的地方。")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("与其现在编一个，不如先去问一句 —— 猜错了再拿去道歉，比不道歉更伤人。")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        withAnimation { step = .perspective }
                    } label: {
                        Text("先不写了，去问一句")
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundStyle(ThemeManager.Colors.primary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(ThemeManager.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemeManager.Colors.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            }
        }
    }

    // MARK: Step 6 · 骨架

    private var skeletonStep: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            ForEach(RepairSkeleton.lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.id == RepairSkeleton.lines.count - 1
                             ? line.label + RepairSkeleton.closing
                             : line.label)
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // 这里是全流程的出口，也是最容易被"懒得打字"毁掉的一屏：
                        // 用户想清楚了，但要他把话敲出来，很多人会直接复制上一步的内容。
                        VoiceInputButton(
                            text: bindingForSkeleton(line.id),
                            subject: line.label,
                            compact: true
                        )
                    }

                    TextField(line.placeholder, text: bindingForSkeleton(line.id), axis: .vertical)
                        .font(ThemeManager.Typography.body)
                        .lineLimit(1...3)
                        .padding(ThemeManager.Spacing.sm)
                        .background(ThemeManager.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
                        .accessibilityLabel(line.label)
                }
            }

            let composed = RepairSkeleton.render(draft.skeleton)
            if !composed.isEmpty {
                Text(composed)
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .padding(ThemeManager.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard(cornerRadius: ThemeManager.Radius.md)

                Button {
                    UIPasteboard.general.string = composed
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制这段话",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(PressableStyle())
            }

            Text("这只是一次修复动作。它可能不被接受 —— 那也不代表你做错了这一步。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bindingForSkeleton(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                draft.skeleton.indices.contains(index) ? draft.skeleton[index] : ""
            },
            set: { newValue in
                while draft.skeleton.count <= index { draft.skeleton.append("") }
                draft.skeleton[index] = newValue
            }
        )
    }

    // MARK: 通用部件

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(ThemeManager.Typography.subheadline)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
    }

    private func editor(
        _ text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat = 110,
        showsVoice: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            TextEditor(text: text)
                .font(ThemeManager.Typography.body)
                .focused($focused)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(ThemeManager.Spacing.sm)
                .background(ThemeManager.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(ThemeManager.Typography.body)
                            .foregroundStyle(ThemeManager.Colors.textSecondary.opacity(0.7))
                            .padding(.horizontal, ThemeManager.Spacing.md)
                            .padding(.vertical, ThemeManager.Spacing.md)
                            .allowsHitTesting(false)
                    }
                }

            if showsVoice {
                HStack(spacing: ThemeManager.Spacing.sm) {
                    VoiceInputButton(text: text, subject: placeholder)
                    Text(text.wrappedValue.isEmpty ? "也可以按住说话，自动转成文字" : "\(text.wrappedValue.count) 字")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func issueList(_ issues: [RepairIssue]) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.severity == .blocking
                              ? "exclamationmark.circle.fill"
                              : "info.circle")
                            .font(.caption)
                            .foregroundStyle(issue.severity == .blocking
                                             ? ThemeManager.Colors.danger
                                             : ThemeManager.Colors.accent)
                        Text(issue.message)
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(ThemeManager.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeManager.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    /// 依据折叠区。
    ///
    /// 默认收起，但**必须存在**：用户有权知道这个工具凭什么这么问。
    /// 主动标注证据强度（"这是案例归纳，不是实验结论"）比多引一条文献更能建立信任。
    private func theoryCard(_ theory: RepairTheory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { showTheory.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.book.closed")
                        .font(.caption)
                    Text("为什么这么做")
                        .font(ThemeManager.Typography.caption)
                    Spacer()
                    Image(systemName: showTheory ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            if showTheory {
                VStack(alignment: .leading, spacing: 6) {
                    Text(theory.claim)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                    Text("—— \(theory.source)")
                        .font(.caption2)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                    Text(theory.caveat)
                        .font(.caption2)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .italic()
                }
            }
        }
    }

    // MARK: 导航

    private var blocking: Bool {
        switch step {
        case .safety:
            return false
        case .action:
            return RepairLinter.hasBlocking(RepairLinter.lintAction(draft.action))
                || draft.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .explanation:
            return RepairLinter.hasBlocking(RepairLinter.lintExplanation(draft.explanation))
        case .losses:
            return !RepairLinter.hasSubstantiveLoss(draft.lossDict)
        case .perspective:
            return RepairLinter.hasBlocking(RepairLinter.lintQuestion(draft.question))
                || draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .repairAction:
            return RepairLinter.hasBlocking(RepairLinter.lintRepairAction(
                time: draft.repairWhen,
                action: draft.repairWhat,
                ifRefused: draft.ifRefused
            ))
        case .skeleton:
            return RepairSkeleton.render(draft.skeleton).isEmpty
        }
    }

    private var navigation: some View {
        HStack(spacing: ThemeManager.Spacing.sm) {
            if step.rawValue > RepairStep.action.rawValue {
                Button {
                    if let previous = RepairStep(rawValue: step.rawValue - 1) {
                        withAnimation(.smooth(duration: 0.2)) { step = previous }
                    }
                } label: {
                    Text("上一步")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(ThemeManager.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }

            if step == .skeleton {
                primaryButton("完成", blocked: blocking) { reset() }
            } else {
                primaryButton("下一步", blocked: blocking) {
                    if let next = RepairStep(rawValue: step.rawValue + 1) {
                        focused = false
                        withAnimation(.smooth(duration: 0.2)) { step = next }
                    }
                }
            }
        }
        .padding(.top, ThemeManager.Spacing.sm)
    }

    /// 主按钮。
    ///
    /// 禁用态不能只靠 `.opacity`：实测在深色模式下，半透明的深靛蓝
    /// 和正常态几乎看不出差别 —— 用户会以为按钮坏了，而不是以为"还差一步"。
    /// 换成中性底色 + 次要文字色，两种主题下都明确。
    private func primaryButton(
        _ title: String,
        blocked: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(blocked ? ThemeManager.Colors.textSecondary : .white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(blocked ? ThemeManager.Colors.surfaceElevated : ThemeManager.Colors.onFillPrimary)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(blocked)
        .accessibilityHint(blocked ? "先改掉上面标红的地方" : "")
    }

    private func reset() {
        RepairDraftStore.clear()
        withAnimation(.smooth(duration: 0.2)) {
            draft = RepairDraft()
            step = .safety
        }
    }
}
