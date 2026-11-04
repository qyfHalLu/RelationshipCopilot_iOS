//
//  AIAssistService.swift
//  RelationshipCopilot
//
//  快速工具（吵架复盘 / 话术急救 / 道歉生成）的 AI 接入。
//
//  修复报告 A2 / E2：
//  原 `QuickToolsView.generateAIResponse()` 在固定 2 秒延时后返回**硬编码字符串**——
//  4 个工具的输出与用户输入几乎无关（唯一用到输入的是 `userInput.prefix(20)` 拼进一句话），
//  其中一个工具对任何人都返回"综合评分：72/100"。这是产品宣称"AI 驱动"却完全失真的根因。
//
//  现在：真实调用模型，并把工具的系统提示词集中在这里维护。
//  失败或未配置时，UI 会退回到**明确标注为「通用参考」**的静态建议，而不是假装是 AI 结果。
//

import Foundation

enum QuickToolKind: String, CaseIterable, Identifiable, Sendable {
    case conflict
    case phrase
    case apology

    var id: String { rawValue }

    /// 这个工具的产出**是否必须由用户改成自己的话再说出口**。
    ///
    /// ## 这条判断从哪来
    ///
    /// 用户提了一个非常准的问题：如果被道歉的人知道这段话是 AI 生成的，
    /// 只会更生气 —— 因为"你连道歉都要别人代笔"。
    /// 这不是误用，是**设计错位**：道歉的价值不在文字得体，
    /// 而在"我有没有真的理解我伤到你哪里"，而 AI 代写恰好跳过了理解。
    ///
    /// 所以「替你说话」类工具必须降级为「陪你想」：
    /// 产出的是要自己想清楚的几件事，而不是一段可以复制的成品。
    /// 吵架复盘不受影响 —— 它本来就只帮你看清，不产出要说的话。
    var requiresOwnWords: Bool {
        switch self {
        case .conflict: return false
        case .phrase, .apology: return true
        }
    }

    var title: String {
        switch self {
        case .conflict: return "吵架复盘"
        case .phrase:   return "开口准备"
        case .apology:  return "道歉准备"
        }
    }

    var icon: String {
        switch self {
        case .conflict: return "bubble.left.and.bubble.right.fill"
        case .phrase:   return "bandage.fill"
        case .apology:  return "envelope.fill"
        }
    }

    var detail: String {
        switch self {
        case .conflict: return "只有你一个人写，把刚才那件事理清楚"
        // 原文是「给你几句现在就能发出去的话」—— 和它自己的提示词直接冲突：
        // 提示词明写「不要给他一段可以复制粘贴的话」。
        // 列表页承诺发出去的话，进去却只给要点，用户会觉得功能坏了。
        case .phrase:   return "想清楚要开口说什么，不替你说"
        // 不写具体步数。写死数字的代价是：以后调整流程就没人记得改这一行，
        // 而这里曾经写的是「六步」，实际已经是七步。
        case .apology:  return "一步一步想清楚，不给你现成的话"
        }
    }

    /// 输入框占位提示。要求用户给出**具体**信息，否则 AI 只能泛泛而谈。
    var inputPrompt: String {
        switch self {
        case .conflict:
            // 「双方各自说了什么」这个问法被刻意改掉了。
            // 让一个人转述两个人的话，等于请他替对方作证 ——
            // 由此得到的任何"分析"都是用户视角的复述，AI 再基于它评判对错，
            // 就是把单方叙事包装成中立结论。真正的双人评理走「评理」入口，
            // 两侧各写各自的一份，互不可见。这里只处理"你自己这一份"。
            return "刚才发生了什么？只说你自己看到、听到的和你自己的感受。"
        case .phrase:
            return "现在的场景是什么？比如：对方心情不好 / 我想表白 / 我要拒绝一件事"
        case .apology:
            return "你做错了什么？对方的反应是什么？"
        }
    }

    /// 系统提示词。统一约束：不给"关系分数"，只给可执行的下一步。
    ///
    /// ## 为什么 common 里没有"给出可以直接使用的原话"
    ///
    /// 这句话原本在 common 的第三条，对每个工具都生效。但它和
    /// `phrase` / `apology` 的任务正文**直接冲突** —— 那两个工具的正文是
    /// 「不要给他一段可以复制粘贴的话」。一条自相矛盾的提示词会让模型在
    /// 两种行为之间摇摆：有时给成品，有时不给。
    ///
    /// 只有 `conflict` 真的需要原话（它给的是"今晚可以说的一句"），
    /// 所以那一条下移到 `conflict` 自己身上。
    ///
    /// 同样的修正也做在 `Tools/ai-proxy/worker.js` 里 —— 内测走代理，
    /// 两条路的提示词必须一致，否则同一个工具在调试版和内测版表现不同。
    var systemPrompt: String {
        let common = """
        你是一位务实的关系沟通教练。要求：
        1. 只基于用户提供的信息回答，信息不足时明确说明"信息不足，需要更多细节"，不要编造。
        2. 不要说教、不要长篇大论，输出不超过 220 字。
        3. 不提供心理诊断、医疗或法律建议。若涉及自伤、暴力、虐待，优先建议寻求专业帮助与紧急支持。
        4. 用简体中文，分点但不使用复杂格式。
        """

        switch self {
        case .conflict:
            return common + """

            5. 给出可以直接使用的原话，而不是"应该多沟通"这类空话。

            任务：帮用户把这次争执理清楚。**你只读到用户一个人的视角**，
            因此不得猜测对方怎么想、不得判断谁对谁错、不得分配责任。
            输出四段：
            【你当时遇到的是什么】用一句话中立复述用户描述的事实
            【真正卡住你的那一点】从用户的描述里指出最难受的那一处
            【你今晚可以说的一句】给 1 句第一人称的话，不指责对方
            【你自己能做的一件事】给 1 个只依赖用户自己的具体动作
            如果用户想两个人一起把这件事说清，提示他去「评理」入口，各写一份。
            """
        case .phrase:
            return common + """


            任务：帮用户准备「这次要怎么开口」，**不要给他一段可以复制粘贴的话**。

            为什么：如果对方发现这段是 AI 写的，会比他原本说不出口更糟 ——
            那意味着"你连跟我说句话都要别人代笔"。你的作用是帮他想清楚，不是替他说。

            输出三段：
            【你想要的是什么】一句话，用"我希望……"的口吻，具体到可以答应或拒绝
            【对方可能在意什么】一句话，只给可能性，用"他可能会觉得……"而不是断言
            【最坏的情况你怎么接】一句话，让他知道就算被拒绝也不会崩

            最后给一句**故意粗糙的示范**：短句、口语、可以不完整，
            像人脱口而出的那种，不要写成文案。
            示范前面明确写"粗糙示范，改成你自己的说法"。
            """
        case .apology:
            return common + """


            任务：帮用户弄清楚「这次道歉到底在道什么」，**不要写一段可以复制粘贴的道歉**。

            为什么：一段 AI 写好的道歉，即使文字完美，也绕过了真正重要的那一步 ——
            理解自己伤到了对方哪里。而对方要的恰恰是那一步。
            被识破时它还会变成二次伤害："你连道歉都不肯自己说。"

            输出三段，每段一句话，不写成完整段落：
            【你具体做了什么】只写行为，不写动机，不要加"但是"
            【对方因此失去了什么】这是最容易漏掉的一段：不是"让对方不开心"，
            而是具体的损失 —— 白等的时间、被辜负的期待、在别人面前丢掉的面子、
            之后再也不敢开口的那件事
            【你能承诺什么】必须是你做得到的具体动作，不是"以后注意"

            结尾给一句提醒：想清楚这三件事，用你自己的话说。不用漂亮，真实比漂亮有用。
            """
        }
    }

    /// 离线兜底建议。**必须明确标注为通用参考**，不能伪装成 AI 结果。
    var offlineReference: String {
        switch self {
        case .conflict:
            return """
            通用参考（未个性化）

            1. 先各自说完，不打断。复述对方的意思，确认没理解错。
            2. 说「我感到…」而不是「你总是…」。
            3. 找出这一次真正分歧的那一件事，别的先放下。
            4. 约定一个下次可以用的暂停信号。
            """
        case .phrase:
            return """
            通用参考（未个性化）

            · 温和开场：「我想认真跟你说件事，现在方便吗？」
            · 承接情绪：「听起来你今天挺难受的，我在。」
            · 提出请求：「我需要你帮我做一件事，可以吗？」
            """
        case .apology:
            return """
            通用参考（未个性化）

            「关于___这件事，我做了___，让你感到___。
            这是我的问题，不怪你。
            以后我会___。如果你还愿意，我想当面跟你聊一次。」
            """
        }
    }
}

// MARK: - 失败时的产出决策

/// 快速工具生成失败时，界面该显示什么。
///
/// ## 为什么要把这个决策从 View 里抽出来
///
/// 它原来写在 `QuickToolsView.generate()` 的 `catch` 里，两处分支：
/// `catch let appError as AppError` 有判断，`catch`（兜底）**无条件**降级成
/// 离线参考。后者会把 401 / 超时 / 500 / 输出截断全部显示成
/// 「通用参考（未个性化）」—— 用户以为 AI 给了他建议，其实一次都没调用到。
///
/// 这在逻辑层看只是"少个判断"，在体验层是**故障被静默掩盖**：
/// 内测用户不会来报告"它给了通用参考"，因为他不知道本该是定制的。
///
/// 抽成纯函数是为了能被单测钉住。只要这个函数在，`catch` 写错就会被抓到。
enum AssistFallback {

    /// 退化结果：显示什么、以及它算不算 AI 产出。
    enum Outcome: Equatable {
        /// 真的拿到了 AI 内容。
        case generated(String)
        /// 展示离线通用参考（**不是** AI 产出，界面须标注）。
        case reference(String)
        /// 不展示任何内容，只报错。
        case failed(AppError)

        var text: String? {
            switch self {
            case .generated(let text), .reference(let text): return text
            case .failed: return nil
            }
        }

        var isAIGenerated: Bool {
            if case .generated = self { return true }
            return false
        }
    }

    /// 只有这两种错误允许降级：它们说明"这台设备眼下确实没有 AI 可用"，
    /// 而且都是用户自己能理解的状况。
    ///
    /// 其余（401、超时、500、解析失败）一律报错 —— 那是该被看见的故障。
    static func outcome(for error: AppError, tool: QuickToolKind) -> Outcome {
        switch error {
        case .aiNotConfigured, .quotaExceeded:
            return .reference(tool.offlineReference)
        default:
            return .failed(error)
        }
    }
}
