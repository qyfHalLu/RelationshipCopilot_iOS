//
//  SafetyScreen.swift
//  RelationshipCopilot
//
//  安全前置筛查。**必须在调用模型之前跑，不能依赖模型自觉。**
//
//  为什么放在客户端：
//  参考产品（Capybara Court）把这条写在提示词里（"当读到自伤/虐待/紧急信号时不给判决"），
//  但提示词是可被绕过的建议。涉及自伤、暴力、控制的内容，
//  一旦模型"照常评理"，后果不是体验问题。因此这里做**词表前置拦截 + 模型二次确认**：
//   1. 命中高危词 → 直接不调用模型，进入求助引导，零延迟
//   2. 未命中 → 正常评理，但提示词里仍保留安全条款作为第二道闸
//
//  命中后的行为是**停止评理**，不是"温柔地评理"。见设计文档 6.3 第 7 条。
//

import Foundation

// MARK: - 筛查结论

enum SafetyConcern: String, Sendable, CaseIterable {
    /// 自伤 / 自杀
    case selfHarm
    /// 对他人施暴或被施暴
    case violence
    /// 强制控制、跟踪、威胁
    case coerciveControl

    var displayName: String {
        switch self {
        case .selfHarm:        return "自伤风险"
        case .violence:        return "暴力风险"
        case .coerciveControl: return "控制与威胁"
        }
    }
}

struct SafetyScreeningResult: Equatable, Sendable {
    let concerns: [SafetyConcern]
    /// 命中的原始词（用于内部日志，**不展示给用户**）。
    let matchedTerms: [String]

    var isBlocking: Bool { !concerns.isEmpty }

    static let clear = SafetyScreeningResult(concerns: [], matchedTerms: [])
}

// MARK: - 筛查器

enum SafetyScreen {

    /// 高危词表。刻意保持**短而硬**：宁可漏掉边缘表述（模型还有第二道闸），
    /// 也不要因为词表过宽把正常抱怨误判成危机。
    ///
    /// 每条都对应真实表达，不收录"生气""吵架""难过"这类正常情绪词。
    static let highRiskTerms: [String: SafetyConcern] = [
        // 自伤
        "不想活了": .selfHarm,
        "想死": .selfHarm,
        "自杀": .selfHarm,
        "轻生": .selfHarm,
        "割腕": .selfHarm,
        "跳楼": .selfHarm,
        "活不下去": .selfHarm,
        "结束自己": .selfHarm,
        "伤害自己": .selfHarm,

        // 暴力
        "打我": .violence,
        "打了我": .violence,
        "动手打": .violence,
        "掐我": .violence,
        "推我": .violence,
        "扇我": .violence,
        "砸东西": .violence,
        "拿刀": .violence,
        "家暴": .violence,
        "受伤了": .violence,

        // 控制与威胁
        "威胁我": .coerciveControl,
        "不让我出门": .coerciveControl,
        "查我手机": .coerciveControl,
        "跟踪我": .coerciveControl,
        "限制我": .coerciveControl,
        "要毁了我": .coerciveControl,
        "发我照片": .coerciveControl
    ]

    /// 扫描单份证词。
    static func screen(_ testimony: DisputeTestimony) -> SafetyScreeningResult {
        let text = TestimonyQuestion.allCases
            .map { testimony.answer(for: $0) }
            .joined(separator: "\n")
        return screen(text)
    }

    /// 扫描任意文本（也用于扫描 AI 输出，防止模型在评理里引入这些话题）。
    static func screen(_ text: String) -> SafetyScreeningResult {
        guard !text.isEmpty else { return .clear }

        var concerns = Set<SafetyConcern>()
        var matched: [String] = []

        for (term, concern) in highRiskTerms where text.contains(term) {
            concerns.insert(concern)
            matched.append(term)
        }

        guard !concerns.isEmpty else { return .clear }
        // 按枚举顺序稳定输出，避免每次顺序不同导致的 UI 抖动
        let ordered = SafetyConcern.allCases.filter { concerns.contains($0) }
        return SafetyScreeningResult(concerns: ordered, matchedTerms: matched.sorted())
    }

    /// 命中后展示给用户的内容。**不给评理，不给建议，只给求助路径。**
    static func guidance(for concerns: [SafetyConcern]) -> SafetyGuidance {
        let needsEmergency = concerns.contains(.violence) || concerns.contains(.selfHarm)
        return SafetyGuidance(
            title: "这件事不适合在这里评理",
            body: "你写下的内容里出现了可能涉及安全的情况。这种情况下，评理帮不上忙，也不该给谁对谁错的判断。",
            actionLine: needsEmergency
                ? "如果你或身边的人正处在危险中，请立刻联系当地紧急服务，或找一位能马上到场的人。"
                : "如果这段关系里有让你害怕的部分，找一个现实中的专业支持会比任何 App 更有用。",
            concerns: concerns
        )
    }
}

/// 安全引导文案（由 UI 直接渲染，不经过模型）。
struct SafetyGuidance: Equatable, Sendable {
    let title: String
    let body: String
    let actionLine: String
    let concerns: [SafetyConcern]
}
