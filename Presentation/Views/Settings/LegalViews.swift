//
//  LegalViews.swift
//  RelationshipCopilot
//
//  修复报告 C3 / F3 / D5：
//  - 原 `SettingsView` 的「隐私政策」「数据管理」「账号安全」「帮助与反馈」「评分」全是
//    `NavigationLink { Text("隐私政策") }` 之类的占位页，且设置页本身在导航中不可达。
//  - 原登录页的「用户协议 / 隐私政策」按钮是空动作 `Button("用户协议") {}`。
//  两者都是 App Store 5.1.1 的直接拒绝项。
//
//  这里提供**真实可读**的条款内容，描述与代码实际行为一致（本地存储、麦克风与语音识别用途、
//  可删除全部数据、AI 分析的边界）。若日后接入自有服务端，需同步更新本文件。
//

import SwiftUI

enum LegalDocument: String, Identifiable {
    case privacy
    case terms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "隐私政策"
        case .terms:   return "用户协议"
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                    Text(legalText)
                        .font(ThemeManager.Typography.callout)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                        .textSelection(.enabled)
                }
                .padding(ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var legalText: String {
        switch document {
        case .privacy: return Self.privacyText
        case .terms:   return Self.termsText
        }
    }

    private static let privacyText = """
    最后更新：2026 年 11 月 2 日

    一、我们处理哪些数据

    1. 你主动创建的内容：人物档案（姓名、关系类型、生日、纪念日、备注）、承诺、对话记录与录音转写文本。
    2. 录音：仅在你点击「开始录音」并授权麦克风后采集。
    3. 语音识别：使用 Apple 系统语音识别能力把录音转成文字。若设备支持端侧识别，我们优先在本机完成；
       否则由 Apple 的语音识别服务处理音频。
    4. 登录标识：手机号与本地会话令牌，用于在本机恢复登录状态。

    二、数据存放在哪里

    1. 上述内容默认**只保存在你的设备本地**（应用沙盒）。当前版本不提供云端同步。
    2. 录音文件保存在应用的缓存目录，**不进入 iCloud 备份**；一次记录完成后会被删除，只保留文字。
    3. 会话令牌保存在系统钥匙串（Keychain），并设置为「仅本机、解锁后可读」。

    三、关于 AI 分析

    当你使用 AI 分析功能时，被分析的**对话文字**会发送到 AI 服务进行处理，以生成关系分析结果。
    我们不会发送你的通讯录、位置、相册或未选择录音的任何内容。
    AI 输出由模型生成，可能不准确，仅供参考，不构成心理、医疗或法律建议。
    如你或他人正处于危机中，请优先联系专业机构或紧急服务。

    四、我们不做的事

    1. 不收集广告标识符，不做跨 App 跟踪。
    2. 不出售、不交换你的个人数据。
    3. 不在后台自动录音。

    五、你的权利

    1. 你可以在「我的 → 数据管理」中导出或**永久删除**全部本地数据。
    2. 删除后不可恢复，请自行确认。
    3. 卸载 App 会一并清除本地数据。

    六、儿童

    本应用不面向 14 周岁以下儿童。

    七、联系我们

    如对本政策有疑问，可通过 App Store 页面提供的开发者联系方式与我们联系。
    """

    private static let termsText = """
    最后更新：2026 年 11 月 2 日

    一、服务内容

    关系副驾提供关系记录、承诺追踪与基于 AI 的对话分析。分析结果由算法生成，
    不代表专业心理、医疗或法律意见。

    二、使用规范

    1. 你应确保在录音前已取得对话参与者的同意，并遵守所在地关于录音的法律规定。
    2. 不得利用本应用记录他人隐私用于侵害他人权益。
    3. 不得将本应用用于骚扰、跟踪或任何违法行为。

    三、AI 输出的边界

    AI 可能产生不准确、不完整或不适当的内容。请自行判断，不要将输出作为决策的唯一依据。
    若涉及人身安全、自伤或暴力风险，请立即寻求专业帮助。

    四、数据与责任

    数据默认保存在本机。你需自行负责设备安全与备份。因设备丢失、系统重置或卸载导致的数据丢失，
    我们无法恢复。

    五、变更

    条款更新后会在应用内展示。继续使用即视为接受更新后的条款。
    """
}

/// 通用文档页（帮助与反馈）。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {
                    section(
                        title: "录音没有声音怎么办？",
                        body: "确认「设置 › 隐私与安全性 › 麦克风」与「语音识别」都已允许本应用；录音时屏幕上会显示实时转写，若一直没有文字，说明没收到声音。"
                    )
                    section(
                        title: "为什么分析结果没有评分？",
                        body: "当对话内容太短或识别不到有效信息时，我们不会给出评分——宁可没有，也不编造一个数字。"
                    )
                    section(
                        title: "数据存在哪里？",
                        body: "全部保存在本机。录音文件在分析后即删除，只保留文字。可在「我的 → 数据管理」导出或删除。"
                    )
                    section(
                        title: "如何反馈问题？",
                        body: "请在 App Store 页面通过「App 支持」联系我们，并附上设备型号与系统版本。"
                    )
                }
                .padding(ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("帮助与反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func section(title: String, body text: String) -> some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text(title)
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
            Text(text)
                .font(ThemeManager.Typography.callout)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(padding: ThemeManager.Spacing.md)
    }
}
