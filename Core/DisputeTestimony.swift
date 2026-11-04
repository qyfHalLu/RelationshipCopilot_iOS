//
//  DisputeTestimony.swift
//  RelationshipCopilot
//
//  评理的「证词」模型：固定 4 个问题，双方各写一份。
//
//  设计依据（见 relationshipcopilot_verdict_strength_design.md）：
//   ① 发生了什么        —— 强制区分事实与解释
//   ② 最让你难受的是哪一点 —— 从事实转到情绪，真正的争点在这里
//   ③ 你希望对方怎么做    —— 把抱怨转成可回应的具体诉求
//   ④ 这件事里你自己那一份 —— 强制自我归因（全套设计中最关键的一问）
//
//  第 ④ 问是整套协议的心理支点：人一旦写下"我也有错"，
//  后续任何结论都更容易被接受。参考产品的原始设计即以此为核心。
//
//  本文件为纯 Swift、无框架依赖，可直接用 swiftc 编译成可执行文件跑断言。
//

import Foundation

// MARK: - 四个问题

/// 证词的四个问题。顺序即界面顺序，不得调整（④ 必须在最后）。
enum TestimonyQuestion: Int, CaseIterable, Identifiable, Sendable {
    case happened = 0
    case hurtMost = 1
    case request = 2
    case myPart = 3

    var id: Int { rawValue }

    /// 问题标题。
    var title: String {
        switch self {
        case .happened: return "发生了什么？"
        case .hurtMost: return "最让你难受的是哪一点？"
        case .request:  return "你希望对方怎么做？"
        case .myPart:   return "这件事里，你自己那一份是什么？"
        }
    }

    /// 追问（放在输入框下方，降低"不知道写什么"的空白焦虑）。
    var hint: String {
        switch self {
        case .happened:
            return "只写你看到的、听到的。先别写你猜对方怎么想。"
        case .hurtMost:
            return "不是最生气的地方，是最难受的地方。"
        case .request:
            return "具体到一个动作，不要写「多关心我」。"
        case .myPart:
            return "不用认错，只要写你那一份。写不出就写「我还没想清楚」。"
        }
    }

    /// 单题字数上限。中文 200 字已足够说清一件事，
    /// 且能在 3 分钟内完成 —— 「写不进一页的，大概就不是小矛盾了」。
    static let characterLimit = 200
}

// MARK: - 单份证词

/// 一方写下的证词。四个字段全部必填（允许写"还没想清楚"，但不允许空）。
struct DisputeTestimony: Codable, Equatable, Sendable {

    var happened: String
    var hurtMost: String
    var request: String
    var myPart: String

    var submittedAt: Date

    init(
        happened: String = "",
        hurtMost: String = "",
        request: String = "",
        myPart: String = "",
        submittedAt: Date = Date()
    ) {
        self.happened = happened
        self.hurtMost = hurtMost
        self.request = request
        self.myPart = myPart
        self.submittedAt = submittedAt
    }

    // MARK: 取值

    func answer(for question: TestimonyQuestion) -> String {
        switch question {
        case .happened: return happened
        case .hurtMost: return hurtMost
        case .request:  return request
        case .myPart:   return myPart
        }
    }

    mutating func setAnswer(_ text: String, for question: TestimonyQuestion) {
        let clipped = DisputeTestimony.clip(text)
        switch question {
        case .happened: happened = clipped
        case .hurtMost: hurtMost = clipped
        case .request:  request = clipped
        case .myPart:   myPart = clipped
        }
    }

    // MARK: 完整性

    /// 逐题是否已填写（非空白）。
    var completion: [Bool] {
        TestimonyQuestion.allCases.map { !answer(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isComplete: Bool { completion.allSatisfy { $0 } }

    /// 已完成的题数，用于进度展示（"2 / 4"）。
    var answeredCount: Int { completion.filter { $0 }.count }

    /// 总字数，用于对称性校验的输入侧。
    var totalLength: Int {
        TestimonyQuestion.allCases.reduce(0) { $0 + answer(for: $1).count }
    }

    // MARK: 工具

    /// 按字符裁剪到上限。**不允许靠 minimumScaleFactor 式的"缩字号"来规避超长**，
    /// 这里是硬裁剪并在 UI 上明确提示剩余字数。
    static func clip(_ text: String) -> String {
        guard text.count > TestimonyQuestion.characterLimit else { return text }
        return String(text.prefix(TestimonyQuestion.characterLimit))
    }

    /// 供提示词使用的纯文本渲染。**双方渲染格式必须完全一致**，
    /// 否则"中立"在文本层面就已经不成立。
    func renderedForPrompt() -> String {
        TestimonyQuestion.allCases.map { question in
            "【\(question.title)】\n\(answer(for: question).trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        .joined(separator: "\n\n")
    }
}
