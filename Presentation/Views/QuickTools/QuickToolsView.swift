import SwiftUI
import UIKit

// MARK: - 快速工具
//
// 修复报告 A2 / E2 / C5：
//  - 原实现 4 个工具全部返回**硬编码字符串**：`generateResponse()` 在固定 2 秒延时后
//    调用 `generateAIResponse()`，后者是一段与输入无关的常量文本；
//    「关系体检」对任何人都输出"综合评分：72/100"。
//  - 原 `QuickToolsView` 自带 `NavigationStack`，同时被塞进 tab 与首页 ScrollView，
//    形成 NavigationStack 嵌套。现在它是被 push 的普通页面。
//  - AI 不可用时给出**明确标注为「通用参考」**的离线内容，不伪装成 AI 结果。

struct QuickToolsView: View {

    var body: some View {
        ScrollView {
            VStack(spacing: ThemeManager.Spacing.md) {
                Text("选一个当下最需要的")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(QuickToolKind.allCases) { tool in
                    // 用「直接给目标视图」的 NavigationLink，不用 `NavigationLink(value:)`。
                    //
                    // ## 这里曾经整个模块都点不动
                    //
                    // 原实现是 `NavigationLink(value: tool)` + `.navigationDestination(for:)`
                    // 配一个 `@State path`。但那个 `path` **从来没绑定到任何 NavigationStack**
                    // （本页是被外层 push 的普通页面，自己没有 Stack），
                    // 于是：点首页四宫格 → 停在列表页；再点列表项 → 仍然停在列表页。
                    //
                    // 实测证据（XCUITest 打印）：
                    //   点格子后导航栏仍是「快速工具」
                    //   点列表行后导航栏仍是「快速工具」、详情页占位符不存在
                    // 也就是说**四个工具一个都进不去**，整个功能是死的。
                    //
                    // 直接给目标视图不依赖任何路径注册，是这里最可靠的写法。
                    NavigationLink {
                        QuickToolDestination(kind: tool)
                    } label: {
                        toolRow(tool)
                    }
                    .buttonStyle(.plain)
                }

                if !AIService.shared.isConfigured {
                    noticeCard
                }
            }
            .padding(ThemeManager.Spacing.md)
        }
        .background(ThemeManager.Colors.background)
        .navigationTitle("快速工具")
        .navigationBarTitleDisplayMode(.large)
    }

    private func toolRow(_ tool: QuickToolKind) -> some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: tool.icon)
                .font(.title3)
                .foregroundStyle(ThemeManager.Colors.primary)
                .frame(width: 44, height: 44)
                .background(ThemeManager.Colors.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                Text(tool.detail)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开\(tool.title)")
    }

    private var noticeCard: some View {
        HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
            Image(systemName: "info.circle")
                .foregroundStyle(ThemeManager.Colors.accent)
            Text("当前构建未接入 AI 服务，工具会展示通用参考内容，不会生成个性化建议。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeManager.Colors.accent.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
    }
}

// MARK: - 工具详情

struct QuickToolDetailView: View {
    let tool: QuickToolKind

    @State private var input = ""
    @State private var output: String?
    @State private var isAIGenerated = false
    @State private var isLoading = false
    @State private var error: AppError?
    @State private var copied = false

    @FocusState private var editorFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                    Text(tool.inputPrompt)
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)

                    TextEditor(text: $input)
                        .font(ThemeManager.Typography.body)
                        .focused($editorFocused)
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .padding(ThemeManager.Spacing.sm)
                        .background(ThemeManager.Colors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty {
                                Text("在这里描述…")
                                    .font(ThemeManager.Typography.body)
                                    .foregroundStyle(ThemeManager.Colors.textSecondary.opacity(0.7))
                                    .padding(.horizontal, ThemeManager.Spacing.md)
                                    .padding(.vertical, ThemeManager.Spacing.md)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel(tool.inputPrompt)

                    // 语音输入。
                    //
                    // 这些工具的输入动辄上百字（"刚才发生了什么"、"你做错了什么"），
                    // 用键盘敲完再点生成，多数人会中途放弃、只写两句 ——
                    // 而输入太短，模型就只能给通用建议，工具也就废了。
                    // 说比打字快得多，这是让工具真正可用的前提。
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        VoiceInputButton(text: $input, subject: tool.inputPrompt)
                        Text(input.isEmpty ? "也可以按住说话，自动转成文字" : "\(input.count) 字")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }

                generateButton

                if let error, error.isBlocking {
                    errorCard(error)
                }

                if let output {
                    outputCard(output)
                }
            }
            .padding(ThemeManager.Spacing.md)
        }
        .background(ThemeManager.Colors.background)
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if output == nil { editorFocused = true }
        }
    }

    private var generateButton: some View {
        Button {
            Task { await generate() }
        } label: {
            HStack(spacing: ThemeManager.Spacing.sm) {
                if isLoading { ProgressView().tint(.white) }
                Text(isLoading ? "生成中…" : (output == nil ? "生成" : "重新生成"))
                    .font(ThemeManager.Typography.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                LinearGradient(
                    colors: [ThemeManager.Colors.gradientStart, ThemeManager.Colors.gradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(isLoading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func outputCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack {
                Text(isAIGenerated ? "AI 生成" : "通用参考")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(isAIGenerated
                                     ? ThemeManager.Colors.secondary
                                     : ThemeManager.Colors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isAIGenerated
                                 ? ThemeManager.Colors.secondary
                                 : ThemeManager.Colors.accent).opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    // 不叫「复制」：这个名字暗示"拿走直接用"，
                    // 而这类工具的产出一开始就不是给你直接用的。
                    Label(copied ? "已存下" : (tool.requiresOwnWords ? "存下来改" : "复制"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(ThemeManager.Typography.caption)
                }
            }

            Text(text)
                .font(ThemeManager.Typography.callout)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // 「改成你自己的话」这条约束**必须由代码写死，不能靠模型自觉**。
            //
            // 理由：这类工具最容易的失败方式，是用户把生成的东西原样发出去，
            // 被对方看出是 AI 写的 —— 那比一开始说不出口更糟，
            // 因为它把"我说不好"变成了"我不愿意自己说"。
            // 模型的提示词里虽然写了，但模型可能不写、可能写得很轻，
            // 而这条提醒是产品立场，不能交给概率。
            if tool.requiresOwnWords {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.caption2)
                    Text("上面这些是帮你理清思路的，不是让你照念的。发之前用你自己的话改一遍——对方要的是你的话，不是漂亮的话。")
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(ThemeManager.Colors.accent)
                .padding(.top, 2)
            }

            if isAIGenerated {
                Text("内容由 AI 生成，仅供参考，不构成专业建议。")
                    .font(.caption2)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: ThemeManager.Spacing.md)
    }

    private func errorCard(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.danger)
            switch error.recovery {
            case .retry:
                Button("重试") { Task { await generate() } }
                    .font(ThemeManager.Typography.subheadline)
            case .openSettings:
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(ThemeManager.Typography.subheadline)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ThemeManager.Spacing.md)
        .background(ThemeManager.Colors.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
    }

    private func generate() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        editorFocused = false

        do {
            let text = try await AIService.shared.quickTool(kind: tool, input: input)
            apply(.generated(text))
            Telemetry.shared.track(.quickToolOpened)
        } catch let appError as AppError {
            apply(AssistFallback.outcome(for: appError, tool: tool))
        } catch {
            // 走到这里的是非 AppError（不该发生），当未知故障处理。
            apply(.failed(.serverError(-1)))
        }
    }

    /// 把决策结果落到界面上。
    ///
    /// 决策本身在 `AssistFallback.outcome(for:tool:)` 里 —— 那是纯函数、有单测。
    /// 这里只负责赋值，不承担任何判断。
    private func apply(_ outcome: AssistFallback.Outcome) {
        // 空字符串要落成 nil。下面的 `if let output` 只判空值不判空串，
        // 落成 "" 会渲染出一张没有任何文字的空白卡片。
        let text = outcome.text ?? ""
        output = text.isEmpty ? nil : text
        isAIGenerated = outcome.isAIGenerated
        if case .failed(let appError) = outcome {
            error = appError
        }
    }
}
