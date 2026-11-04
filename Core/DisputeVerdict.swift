//
//  DisputeVerdict.swift
//  RelationshipCopilot
//
//  评理结果：「第三方之见」四段式 + 可解性分流。
//
//  核心决策（见 relationshipcopilot_verdict_strength_design.md 第一章）：
//  **不做判决，做评理。砍掉责任百分比。**
//
//  依据一（ADR / WIPO）：rights-based 流程（判谁有理）产生一胜一败并**削弱关系**，
//  只有 interest-based 是双赢。WIPO 原文："与法官或仲裁员不同，调解人不是决策者。"
//  本产品服务的是关系，用会破坏关系的手段解决关系问题，是模式错配。
//
//  依据二（Gottman）：69% 的关系冲突是永久性的，本质不可解决，只能 manage。
//  而对永久性问题「判决」会强化 mutual vilification（互相妖魔化），
//  下次争执多一个"上次判你错得多"的弹药 —— 不只是无效，是**负效**。
//
//  依据三：百分比是伪精度。AI 测不出责任，55/45 传达的是"我算过"的虚假确定感。
//  这与刚删除的 `RelationshipHealth.score = 70 + intimacy * 3` 完全同构。
//
//  因此：判事不判人 —— 判「在争什么 / 怎么升级 / 卡在哪 / 能不能解决」，
//  不判「谁对 / 谁错得多 / 谁该道歉 / 谁性格有问题」。
//

import Foundation

// MARK: - 可解性

/// 冲突类型。**这是本产品最核心的差异化判断**。
///
/// 参考产品（Capybara Court）对所有案子使用同一套判词格式，这是它的盲点。
/// Gottman 的 69% 实证说明：对永久性问题给"解决方案"注定失败。
enum DisputeSolvability: String, Codable, Sendable, CaseIterable {
    /// 可解决型：具体安排、单次事件、信息不对称。
    case solvable
    /// 永久型：性格、价值观、原生家庭、生活习惯的根本差异。
    case perpetual

    /// 面向用户的标签。
    var displayName: String {
        switch self {
        case .solvable:  return "这件事能解决"
        case .perpetual: return "这件事大概会一直在"
        }
    }

    /// 结案页的一句解释。永久型那句是**情绪释放**，不是免责声明。
    var explanation: String {
        switch self {
        case .solvable:
            return "它卡在一个具体的安排上，所以有得谈。"
        case .perpetual:
            return "研究发现，关系里约 69% 的冲突源自性格与价值观差异，本来就不会消失。你们的这一类属于那 69%。不需要解决它，需要一个能长期共处的说法。"
        }
    }
}

// MARK: - 评理结果

/// 「第三方之见」。四个必填段 + 一个按分流二选一的行动段。
///
/// **没有任何表示责任分配的字段，这是刻意的。**
/// 若未来想加，请先读本文件头部三条依据。
struct DisputeVerdict: Codable, Equatable, Sendable {

    /// ① 重命名争点：把「谁对」偷换成「我们在争两件不同的事」。
    var reframe: String

    /// ② A 方想被听见的那一句。
    var needA: String
    /// ② B 方想被听见的那一句。**与 needA 必须字数相当**。
    var needB: String

    /// ③ 共同卡点。措辞必须用「你们卡在…」，不得用「你在…」。
    var stuckPoint: String

    /// 可解性判定。
    var solvability: DisputeSolvability

    /// ④ 可解决型：今晚/本周就能做的一个具体动作。
    var action: String?
    /// ④ 永久型：可以长期共存的说法。
    var coexistence: String?

    var generatedAt: Date

    init(
        reframe: String,
        needA: String,
        needB: String,
        stuckPoint: String,
        solvability: DisputeSolvability,
        action: String? = nil,
        coexistence: String? = nil,
        generatedAt: Date = Date()
    ) {
        self.reframe = reframe
        self.needA = needA
        self.needB = needB
        self.stuckPoint = stuckPoint
        self.solvability = solvability
        self.action = action
        self.coexistence = coexistence
        self.generatedAt = generatedAt
    }

    // MARK: 分流结论

    /// 当前分流下应当展示的第四段。可解决型没有 action 时返回 nil（不编造）。
    var closing: String? {
        switch solvability {
        case .solvable:  return normalized(action)
        case .perpetual: return normalized(coexistence)
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 质量校验

    /// 中立性校验结果。**必须由代码判定，不能只写在提示词里** ——
    /// 这是"中立"唯一可被机器验证的表征。
    struct SymmetryCheck: Equatable, Sendable {
        /// 两段字数比（较小 / 较大），1.0 表示完全等长。
        let ratio: Double
        /// 是否通过（≥ 0.8，即字数差 ≤ 20%）。
        let passed: Bool
        /// 一票否决：任一方为空。
        let hasEmpty: Bool
    }

    /// 默认对称阈值。字数差 ≤20%（ratio ≥ 0.8）。
    static let symmetryThreshold: Double = 0.8

    var symmetry: SymmetryCheck {
        let a = needA.trimmingCharacters(in: .whitespacesAndNewlines).count
        let b = needB.trimmingCharacters(in: .whitespacesAndNewlines).count
        if a == 0 || b == 0 {
            return SymmetryCheck(ratio: 0, passed: false, hasEmpty: true)
        }
        let ratio = Double(min(a, b)) / Double(max(a, b))
        return SymmetryCheck(ratio: ratio, passed: ratio >= Self.symmetryThreshold, hasEmpty: false)
    }

    /// 四段是否齐备且未触发否决项。
    var isDeliverable: Bool {
        !reframe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !stuckPoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && closing != nil
            && symmetry.passed
    }

    // MARK: 带走

    /// 可复制/分享的纯文本版本。
    ///
    /// ## 为什么需要它
    ///
    /// 结果页原本只有「沉淀为承诺」和「重新生成」两个动作 ——
    /// 用户看完就没了。而第四段那句「今晚可以做的一件事」恰恰是最需要执行、
    /// 也最需要发给对方的内容。不能复制，用户只能截图。
    ///
    /// ## 格式上的两个约束
    ///
    /// ① **不加任何评价性文字**（"希望你…""建议你…"）。一旦加了，
    ///    这段文字就从"第三方之见"变成了"我在教育你"，转发出去会激化矛盾。
    /// ② 两侧用「你 / TA」而不是 A/B 或甲方乙方 —— 转给对方时读起来才不别扭。
    ///    但同机模式下双方都写过，用「你/TA」会错位，所以用中性的「一方 / 另一方」。
    var shareText: String {
        var parts: [String] = []

        parts.append("① 你们其实在争两件事")
        parts.append(reframe.trimmingCharacters(in: .whitespacesAndNewlines))
        parts.append("")

        parts.append("② 各自想被听见的一句")
        parts.append("一方：" + needA.trimmingCharacters(in: .whitespacesAndNewlines))
        parts.append("另一方：" + needB.trimmingCharacters(in: .whitespacesAndNewlines))
        parts.append("")

        parts.append("③ 你们卡在哪")
        parts.append(stuckPoint.trimmingCharacters(in: .whitespacesAndNewlines))

        if let closing {
            parts.append("")
            parts.append(solvability == .solvable
                         ? "④ 今晚可以做的一件事"
                         : "④ 可以长期这么放着的说法")
            parts.append(closing)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: 沉淀为承诺

    /// 这条结果**是否可以被沉淀成一条可打卡的承诺**。
    ///
    /// ## 为什么只有 solvable 可以
    ///
    /// 可解决型的第四段是一个**具体动作**（"这周找一次，她说完之后你先只说一句…"），
    /// 它有明确的完成条件，能打卡、能算连续天数。
    ///
    /// 永久型（perpetual）的第四段是**共存说法**（"约定一句话：我现在只想被听"），
    /// 它不是一次性的行为，而是长期的态度。把它做成打卡项会变成
    /// "每天打卡：我今天有在听吗" —— 这既不可验证，也会把一段关系的相处方式
    /// 降格成一个 KPI。**那是这个产品明确反对的东西**（见 verdict_strength_design 第 3 章）。
    ///
    /// 还有一个更硬的理由：`action` 为空时不编造（解析器已保证）。
    /// 没有具体动作就没有可执行项，按钮必须消失，而不是转成一条空壳承诺。
    var canBecomePromise: Bool {
        guard solvability == .solvable else { return false }
        guard let action else { return false }
        return !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 禁用措辞自检
    //
    // 提示词里的禁令必须能在客户端复核。这里做的是**输出侧兜底**：
    // 若模型仍然写出「你错了 60%」这类表述，直接判定不可交付，走降级路径。

    /// 出现即判定不可交付的片段（责任分配 / 人格评价）。
    static let forbiddenPhrases: [String] = [
        "%", "百分之", "责任比", "责任划分", "过错比例",
        "谁对谁错", "是对的", "是错的",
        "你错了", "TA 错了", "他错了", "她错了",
        "性格有问题", "人品", "该道歉的是"
    ]

    /// 扫描整个结果里是否出现禁用措辞。返回命中的片段（空 = 通过）。
    var forbiddenHits: [String] {
        let haystack = [reframe, needA, needB, stuckPoint, action ?? "", coexistence ?? ""]
            .joined(separator: "\n")
        return Self.forbiddenPhrases.filter { haystack.contains($0) }
    }

    var passesContentGuards: Bool { forbiddenHits.isEmpty }
}
