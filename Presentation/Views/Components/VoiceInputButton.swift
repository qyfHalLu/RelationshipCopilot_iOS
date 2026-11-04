//
//  VoiceInputButton.swift
//  RelationshipCopilot
//
//  可复用的语音输入按钮：挂在任意文本框旁边，点一下开始听，边说边出字。
//
//  ## 为什么单独抽一个组件
//
//  「写不下那么长」是这类场景最真实的障碍：吵架后让人用键盘敲两百字，
//  多数人会放弃，最后只写两句，AI 也就给不出有用的东西。
//  但这个能力要在三四处长文本输入里都用（快速工具、评理四题、备注），
//  每处各写一遍必然不一致 —— 一处有录音提示、一处没有，一处能取消、一处不能。
//
//  ## 交互约定
//
//  · 只在**文本框为空或光标在末尾**时追加，不覆盖用户已经打好的字
//  · 录音中按钮变红并随音量呼吸，让"到底有没有在录"这件事可见
//  · 再点一次停止；长按菜单提供「取消」（丢弃本次识别）
//  · **同一屏只有一个能录**（见 `VoiceInputCoordinator`）：
//    另开一个会把当前这个停掉，否则两个输入框会同时进字
//

import SwiftUI

struct VoiceInputButton: View {

    /// 识别结果要写进哪个文本。
    @Binding var text: String

    /// 用于无障碍描述「说什么」。
    var subject: String = "内容"

    /// 紧凑样式：只有图标，不显示「正在听…」。
    ///
    /// 用于道歉准备第 3 步那种一格一行的版面 —— 七格各配一个
    /// 完整按钮会挤掉输入框本身的宽度，而那一屏的主要任务是写字。
    /// 但**不能因此省掉麦克风**：那一屏恰恰最难打字。
    var compact: Bool = false

    @State private var service = SpeechInputService()
    /// 本按钮在协调器里的身份。
    @State private var token = UUID()
    /// 开始录音那一刻已有的文字，识别结果追加在它后面。
    @State private var baseText = ""
    /// 每次识别到的文本变化时，用来回写 binding（避免在 View 里做副作用判断）。
    @State private var lastApplied = ""

    private var coordinator: VoiceInputCoordinator { .shared }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: service.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 15, weight: .medium))
                    .symbolEffect(.bounce, value: service.isRecording)
                if service.isRecording && !compact {
                    Text("正在听…")
                        .font(ThemeManager.Typography.caption)
                }
            }
            .foregroundStyle(service.isRecording ? .white : ThemeManager.Colors.primary)
            .padding(.horizontal, service.isRecording && !compact ? 12 : 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(service.isRecording
                        ? ThemeManager.Colors.danger
                        : ThemeManager.Colors.primary.opacity(0.12))
            .clipShape(Capsule())
            .scaleEffect(service.isRecording ? 1 + service.level * 0.06 : 1)
            .animation(.easeOut(duration: 0.12), value: service.level)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(service.isRecording ? "停止语音输入" : "用语音输入\(subject)")
        .accessibilityHint(service.isRecording ? "停止并把听到的内容写进去" : "点一下开始说话，说的话会自动变成文字")
        .contextMenu {
            if service.isRecording {
                Button(role: .destructive) {
                    service.cancel()
                    text = baseText
                    lastApplied = ""
                } label: {
                    Label("取消这次语音输入", systemImage: "xmark.circle")
                }
            }
        }
        .onChange(of: service.transcript) { _, newValue in
            guard service.isRecording || !newValue.isEmpty else { return }
            guard newValue != lastApplied else { return }
            lastApplied = newValue
            text = Self.merge(base: baseText, spoken: newValue)
        }
        .onChange(of: service.isRecording) { _, recording in
            if !recording {
                // 停止后把最终文本固定下来，作为下一次的 base
                baseText = text
                lastApplied = ""
                coordinator.release(token)
            }
        }
        .onChange(of: coordinator.active) { _, active in
            // 被别人抢占：必须自己停，不能只靠"对方会覆盖我"。
            // 这里曾经是个真空 —— 按钮只看自己是否在录，
            // 完全不知道坑已经被别人占了，于是继续录、继续往自己的框里写。
            if active != nil, active != token, service.isRecording {
                service.stop()
            }
        }
        .onDisappear {
            // 页面被关掉时 engine 必须停，否则麦克风指示灯一直亮着。
            // 用户对这一点非常敏感。
            if service.isRecording { service.stop() }
            coordinator.release(token)
        }
        .alert(
            "无法开始语音输入",
            isPresented: Binding(
                get: { service.error != nil },
                set: { if !$0 { service.clearError() } }
            )
        ) {
            Button("知道了", role: .cancel) { service.clearError() }
        } message: {
            Text(service.error?.errorDescription ?? "")
        }
    }

    private func toggle() {
        if service.isRecording {
            service.stop()
            coordinator.release(token)
        } else {
            // 抢占：把正在录的那个停掉，再占坑。
            // 顺序不能反 —— 先占坑再让对方停，会让对方在停的过程中
            // 误以为自己仍被允许录。
            coordinator.claim(token)
            baseText = text
            lastApplied = ""
            Task { await service.start() }
        }
    }

    /// 把识别到的文字接到已有内容后面。
    ///
    /// 需要处理标点：用户已经打了句号，再加一句时不该把两句粘成一个词。
    static func merge(base: String, spoken: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpoken.isEmpty else { return base }
        guard !trimmedBase.isEmpty else { return trimmedSpoken }

        let needsSeparator = !trimmedBase.hasSuffix("。")
            && !trimmedBase.hasSuffix("，")
            && !trimmedBase.hasSuffix("！")
            && !trimmedBase.hasSuffix("？")
            && !trimmedBase.hasSuffix("\n")
        return trimmedBase + (needsSeparator ? "。" : "") + trimmedSpoken
    }
}
