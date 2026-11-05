//
//  GuidedRepair.swift
//  RelationshipCopilot
//
//  「道歉准备」的引导式流程 —— 纯逻辑层，无 UI、无网络、无模型调用。
//
//  ## 为什么这块不用大模型
//
//  设计文档（relationshipcopilot_guided_repair_design.md）里的判断是：
//  模型在"猜对方怎么想"这件事上不可靠，而在"校验用户有没有在辩解"这件事上
//  根本不需要它 —— 那是有明确语言特征的规则问题。
//
//  所以这里全部是确定性的：
//  - 同样的输入永远得到同样的提示（用户不会因为重新生成而困惑）
//  - 零延迟、零 token、离线可用
//  - 每条规则都能被单测钉住，也能被反向验证
//
//  ## 这个文件的核心不是"提问"，是"拦截"
//
//  多数人写道歉时，自我辩护在动笔那一刻就完成了：
//  "我承认我不该发火，但 TA 先……"
//  之后无论看到什么，都只是在跟一个已经闭合的结论商量。
//  所以这里做的是把辩解**识别出来并挪位置**，而不是删掉它 ——
//  人对"被禁止"会反抗，对"被重新安排"不会。
//

import Foundation

// MARK: - 步骤

/// 引导流程的七个步骤。`safety` 是闸门，`skeleton` 是出口。
enum RepairStep: Int, CaseIterable, Identifiable {
    case safety
    case action
    case explanation
    case losses
    case perspective
    case repairAction
    case skeleton

    var id: Int { rawValue }

    /// 1-based 序号，用于界面显示。
    var ordinal: Int { rawValue + 1 }

    static var total: Int { allCases.count }

    var title: String {
        switch self {
        case .safety:       return "先问一句"
        case .action:       return "只写动作"
        case .explanation:  return "解释换个位置"
        case .losses:       return "TA 失去了什么"
        case .perspective:  return "分清关心和猜测"
        case .repairAction: return "让 TA 能认出来"
        case .skeleton:     return "用你的话填"
        }
    }

    /// 这一步要求用户做什么。界面正题。
    var prompt: String {
        switch self {
        case .safety:
            return "在开始之前，一个问题。"
        case .action:
            return "那天你做了什么？只写动作，像监控拍得到的那样。不要写「因为」，不要写「但是」——下一步有地方放它们。"
        case .explanation:
            return "你刚才的理由，现在可以说。只有一个要求：它不能是在要对方体谅你。"
        case .losses:
            return "现在换成 TA。不是「TA 什么感受」——那个太笼统。是 TA 因此失去了什么。"
        case .perspective:
            return "写一个假设，然后把它变成一句可以去问的话。"
        case .repairAction:
            return "最后一件事：TA 怎么会知道你在修复？不是「你要说什么」，是「TA 怎么能认出来」。"
        case .skeleton:
            return "想清楚了，现在用你自己的话填。不用漂亮，真实比漂亮有用。"
        }
    }

    /// 补充说明。刻意短 —— 这一步的正文已经够长了。
    var hint: String? {
        switch self {
        case .safety:       return "这一步决定后面还要不要继续。"
        case .action:       return "例：我答应了六点去接 TA，然后跟同事去喝酒了，手机静音，没接 TA 三个电话。"
        case .explanation:  return "试金石：读一遍，如果听起来像「所以你也不该太怪我」，那就还没到位。"
        case .losses:       return "写不出来的就空着。空着比编好。"
        case .perspective:  return "不能用「你是不是觉得……」，那是把答案塞给对方。"
        case .repairAction: return "具体到哪天、做什么。模糊的承诺对方会当成客套。"
        case .skeleton:     return "填不出来的那格，就是你还没想清楚的地方。留着，别硬填。"
        }
    }

    /// 「为什么这么做」折叠区里的依据。宁可说少，不说错。
    var theory: RepairTheory? {
        switch self {
        case .safety:
            return RepairTheory(
                source: "伦理底线，非研究结论",
                claim: "在权力不对等、或一方害怕另一方反应的关系里，「如何更有效地道歉」这套技术会被反过来用于维持控制。产品不应服务这个场景。",
                caveat: "这是产品立场。"
            )
        case .action:
            return RepairTheory(
                source: "Lazare,《On Apology》, 2004",
                claim: "道歉研究里最常失败的一步是「认错」：含糊、条件化、把解释塞进认错里。解释一旦抢在前面，对方听到的就不是认错，是辩解。",
                caveat: "这是一千多个道歉案例的归纳，不是实验结论。"
            )
        case .explanation:
            return RepairTheory(
                source: "Lazare,《On Apology》, 2004",
                claim: "解释只有在认错完整之后才具建设性。Lazare 还写过一句更狠的：承认「没有借口」，比提供一个虚假或浅薄的解释更有尊严。",
                caveat: "同上，案例归纳。"
            )
        case .losses:
            return RepairTheory(
                source: "Lazare（七种需求）· Fehr & Gelfand, 2010",
                claim: "受害者希望道歉满足的，不只是「被道歉」：重获尊严、确认错不在自己、对未来安全的保证、把话说完的机会……而道歉里与对方自我建构匹配的那一类成分，才显著预测宽恕。中文语境里，共情表达与「面子」的权重高于单纯补偿。",
                caveat: "Fehr & Gelfand 是实验研究；七种需求来自临床与案例归纳。"
            )
        case .perspective:
            return RepairTheory(
                source: "Batson 等, 1997 · Hodges & Klein, 2001 · Eyal & Epley, 2010",
                claim: "「如果我是 TA」会带出个人痛苦，反而更容易防御；「TA 是什么感受」才会带出关心。但关心提升不等于判断变准 —— 多组研究都发现，观点采择能提高共情，却几乎不提高推断对方想法的准确度。",
                caveat: "前一条有实验支持；「准确度不提升」是若干研究的共同结论，不是绝对定律。"
            )
        case .repairAction:
            return RepairTheory(
                source: "Gottman, Love Lab",
                claim: "修复动作说得好不好，几乎不预测它成不成功；但被「错过」比被「拒绝」更伤 —— 拒绝至少还在互动，错过会让对方以为你根本没在试。",
                caveat: "长期追踪与实验室观察的归纳。"
            )
        case .skeleton:
            return RepairTheory(
                source: "产品立场",
                claim: "自己写出来的话才会被自己相信。给一份可以照抄的成品，等于替用户省掉了唯一有用的那一步。",
                caveat: "这是设计取舍，不是研究结论。"
            )
        }
    }
}

/// 一条依据。三部分缺一不可 —— 尤其是 `caveat`：
/// 主动标注证据强度，才是可信度的来源，而不是「科学证明」四个字。
struct RepairTheory: Equatable {
    let source: String
    let claim: String
    let caveat: String
}

// MARK: - 校验问题

struct RepairIssue: Identifiable, Equatable {
    enum Severity: Equatable {
        /// 必须改完才能进下一步。
        case blocking
        /// 只是提示，不拦。
        case warning
    }

    enum Kind: String {
        case tooShort
        case excuse
        case blameShift
        case absolute
        case vagueAction
        case abstractEmotion
        case mindReading
        case closedQuestion
        case missingQuestion
        case vagueTime
        case unverifiable
        case missingRefusal
    }

    let kind: Kind
    let severity: Severity
    let message: String

    var id: String { kind.rawValue + message }
}

// MARK: - 七种损失

/// 受害者希望道歉满足的七种需求，改写成「用户能填」的格子。
///
/// ## 为什么是清单，不是开放提问
///
/// 问「TA 当时什么感受」，多数人只能写出「很难过」——
/// 不是不肯写，是**脑子里没有这个词**。卡住之后他会随便填一个，
/// 产品就拿到了垃圾输入。
///
/// 七个格子放在眼前就不一样了：用户会认出「对，TA 后来问我是不是 TA 太计较」。
/// 这一句是他自己想起来的 —— 自己想起来的才会改变归因。
enum LossCell: String, CaseIterable, Identifiable {
    case dignity
    case notYourFault
    case safety
    case beingHeard
    case cost
    case reparation
    case unsaid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dignity:      return "尊严"
        case .notYourFault: return "错不在 TA"
        case .safety:       return "以后还会不会再来一次"
        case .beingHeard:   return "TA 有没有把话说完"
        case .cost:         return "你有没有付出代价"
        case .reparation:   return "有什么能还回去"
        case .unsaid:       return "TA 没说出来的话"
        }
    }

    var prompt: String {
        switch self {
        case .dignity:      return "TA 在谁面前、被当成了什么人？"
        case .notYourFault: return "TA 有没有开始怀疑是自己太敏感？"
        case .safety:       return "TA 以后会不会担心同样的事再来一次？"
        case .beingHeard:   return "TA 说到一半的时候，你在做什么？"
        case .cost:         return "你为这件事付出过什么？"
        case .reparation:   return "有什么是可以还回去的具体动作？"
        case .unsaid:       return "TA 还有什么没说出来？"
        }
    }

    /// 「写到了」的判据。没有判据的输入框等于没有输入框。
    var criterion: String {
        switch self {
        case .dignity:      return "「TA 妈妈在客厅」比「TA 很难受」具体"
        case .notYourFault: return "「TA 后来问我是不是 TA 太计较」"
        case .safety:       return "「TA 大概不敢再让我接孩子」"
        case .beingHeard:   return "「TA 说到一半我就打断了 TA」"
        case .cost:         return "「没有 —— 这就是问题」也算写到了"
        case .reparation:   return "具体动作，不是「对 TA 好一点」"
        case .unsaid:       return "允许这里写「我不知道」"
        }
    }

    /// 中文语境里权重更高的格子。依据 Fehr & Gelfand：
    /// 道歉成分与对方的自我建构匹配时才有效，而中文用户更偏关系型/集体型，
    /// 共情表达与「面子」的权重高于单纯补偿。
    var isPriority: Bool {
        self == .dignity || self == .notYourFault
    }
}

// MARK: - 校验规则

enum RepairLinter {

    // 这些词一出现，说明用户在解释，而不是在陈述做了什么。
    // 「不过」也在内：道歉语境里它几乎总是辩解的开头。
    private static let excuseMarkers = [
        "因为", "但是", "不过", "我只是", "我也是",
        "没办法", "只好", "不就", "至于吗", "要不是"
    ]

    // 把第二个人拉进责任分配。
    // 「TA 先」归在这里而不是上面：它不是解释，是责任转移 ——
    // 两者的提示语完全不同，混在一起会让用户觉得产品没听懂他在说什么。
    //
    // 同时保留「她/他」：产品文案统一用 TA，但**用户手写时不会**。
    // 这是输入侧检测，要覆盖用户真实会打的字，而不是我们自己规定的写法。
    // 漏掉「她先」的后果很具体：一句典型的转移责任会被判为通过。
    //
    // gender-neutral-scan:off —— 下面是用户输入侧的匹配词表，不是产品文案。
    // 它必须收录「她/他」的拼法，否则漏检；GenderNeutralCopyTests 会跳过本区块。
    private static let blameMarkers = [
        "你也", "她也", "他也", "TA 也",
        "她先", "他先", "TA 先",
        "谁让他", "谁让她"
    ]
    // gender-neutral-scan:on

    // 对方会立刻进入防御的量化词。
    private static let absoluteMarkers = ["总是", "从来", "每次", "老是", "永远"]

    // 「态度不好」「有点过分」是评价，不是动作。
    private static let evaluationOnly = [
        "态度不好", "有点过分", "过分了", "不太好", "不够好",
        "没做好", "做得不好", "错了", "不对"
    ]

    // 抽象情绪词。单独出现时不构成「损失」。
    private static let abstractEmotion = [
        "不开心", "生气", "难受", "委屈", "伤心", "不舒服",
        "不爽", "心情不好", "不高兴"
    ]

    // 猜对方动机。这些句子必须改写成假设。
    private static let mindReadingMarkers = [
        "一定", "肯定", "就是嫌", "就是觉得", "就是不想", "一定是"
    ]

    // 封闭式问句：把答案塞给对方。
    private static let closedQuestionMarkers = [
        "是不是", "对不对", "你有没有觉得", "会不会是", "你是不是", "吧？", "吧?"
    ]

    private static let openQuestionMarkers = ["什么", "怎么", "哪里", "哪一", "为什么", "多少"]

    private static let vagueTimeMarkers = ["改天", "找机会", "有空", "看情况", "以后再说", "下次"]

    private static let unverifiableMarkers = [
        "以后注意", "尽量", "努力", "多体谅", "多关心", "对你好一点", "注意点"
    ]

    private static func firstHit(_ text: String, _ needles: [String]) -> String? {
        needles.first { text.contains($0) }
    }

    // 说明：`trimmedCount(_:)` 已删除（全仓库零调用）。

    // MARK: 第 1 步：只写动作

    static func lintAction(_ text: String) -> [RepairIssue] {
        var issues: [RepairIssue] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return [] }

        if trimmed.count < 6 {
            issues.append(RepairIssue(
                kind: .tooShort,
                severity: .blocking,
                message: "太空了。那一刻你具体说了什么、做了什么？哪怕只有一句。"
            ))
        }

        if let hit = firstHit(trimmed, excuseMarkers) {
            issues.append(RepairIssue(
                kind: .excuse,
                severity: .warning,
                message: "「\(hit)」是解释。不是让你删掉 —— 把它放到第 3 步，它站的位置不对。"
            ))
        }

        if let hit = firstHit(trimmed, blameMarkers) {
            issues.append(RepairIssue(
                kind: .blameShift,
                severity: .warning,
                message: "「\(hit)」把对方拉进来了。这一步只说你自己。"
            ))
        }

        if let hit = firstHit(trimmed, absoluteMarkers) {
            issues.append(RepairIssue(
                kind: .absolute,
                severity: .warning,
                message: "「\(hit)」会让对方立刻防御。这次就说这一次。"
            ))
        }

        if let hit = firstHit(trimmed, evaluationOnly), trimmed.count < 24 {
            issues.append(RepairIssue(
                kind: .vagueAction,
                severity: .blocking,
                message: "「\(hit)」是评价，不是动作。改写成能拍到的东西：你说了哪句话、做了什么。"
            ))
        }

        return issues
    }

    // MARK: 第 2 步：解释不能减责

    static func lintExplanation(_ text: String) -> [RepairIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var issues: [RepairIssue] = []

        if trimmed.contains("所以") && trimmed.contains("才") {
            issues.append(RepairIssue(
                kind: .excuse,
                severity: .warning,
                message: "「所以……才……」是在把原因当理由。原因可以存在，但它不减轻什么。"
            ))
        }

        if let hit = firstHit(trimmed, ["没办法", "只能", "不得不"]) {
            issues.append(RepairIssue(
                kind: .excuse,
                severity: .warning,
                message: "「\(hit)」等于说自己当时没有选择。真有选择，只是你选了别的 —— 那才是对方在意的。"
            ))
        }

        if let hit = firstHit(trimmed, blameMarkers) {
            issues.append(RepairIssue(
                kind: .blameShift,
                severity: .blocking,
                message: "「\(hit)」把第二个人拉进来了。这一步只说你自己。"
            ))
        }

        return issues
    }

    // MARK: 第 3 步：损失

    static func lintLoss(_ text: String) -> [RepairIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var issues: [RepairIssue] = []

        if let hit = firstHit(trimmed, abstractEmotion), trimmed.count < 18 {
            issues.append(RepairIssue(
                kind: .abstractEmotion,
                severity: .blocking,
                message: "「\(hit)」是情绪的词，不是损失。TA 失去了什么具体的东西？"
            ))
        }

        if let hit = firstHit(trimmed, mindReadingMarkers) {
            issues.append(RepairIssue(
                kind: .mindReading,
                severity: .warning,
                message: "「\(hit)」是在替 TA 下结论。改成「我猜……」，猜错了才退得回来。"
            ))
        }

        return issues
    }

    /// 七格全空或全都只是抽象情绪词时，不能进入下一步。
    ///
    /// 这是全流程唯一的**硬闸门**。理由：如果用户连「他失去了什么」
    /// 都说不出来，后面写出来的道歉必然还是「对不起让你不开心」。
    ///
    /// 但闸门不能变成死路 —— 拦下之后要给出口（去问一句），
    /// 否则用户只会退出去，什么也没学到。
    static func hasSubstantiveLoss(_ losses: [LossCell: String]) -> Bool {
        losses.values.contains { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 6 else { return false }
            // 只有抽象情绪词、且没超过一句短话 → 不算写到了
            if firstHit(trimmed, abstractEmotion) != nil && trimmed.count < 18 { return false }
            // 注：「我不知道」会通过 —— 这是诚实，不是敷衍。
            return true
        }
    }

    // MARK: 第 4 步：假设与问句

    static func lintGuess(_ text: String) -> [RepairIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var issues: [RepairIssue] = []

        if let hit = firstHit(trimmed, mindReadingMarkers) {
            issues.append(RepairIssue(
                kind: .mindReading,
                severity: .warning,
                message: "「\(hit)」听起来像你已经知道了。加上「我猜」，是为了让你能退回来。"
            ))
        }

        return issues
    }

    static func lintQuestion(_ text: String) -> [RepairIssue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var issues: [RepairIssue] = []

        if let hit = firstHit(trimmed, closedQuestionMarkers) {
            issues.append(RepairIssue(
                kind: .closedQuestion,
                severity: .blocking,
                message: "「\(hit)」是封闭式问句 —— 你在让 TA 确认你的猜测。改成开放的：那天你是什么感觉？"
            ))
        }

        let hasOpen = firstHit(trimmed, openQuestionMarkers) != nil
        if !hasOpen {
            issues.append(RepairIssue(
                kind: .missingQuestion,
                severity: .blocking,
                message: "这还不是一个开放的问题。用「什么 / 怎么 / 哪里」开头，把回答的空间留给 TA。"
            ))
        }

        return issues
    }

    // MARK: 第 5 步：修复动作

    static func lintRepairAction(time: String, action: String, ifRefused: String) -> [RepairIssue] {
        var issues: [RepairIssue] = []

        let timeText = time.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionText = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let refusedText = ifRefused.trimmingCharacters(in: .whitespacesAndNewlines)

        if let hit = firstHit(timeText, vagueTimeMarkers) {
            issues.append(RepairIssue(
                kind: .vagueTime,
                severity: .blocking,
                message: "「\(hit)」不是时间。具体到哪天、哪个时段。模糊的承诺对方会当成客套。"
            ))
        }

        if timeText.isEmpty {
            issues.append(RepairIssue(
                kind: .vagueTime,
                severity: .blocking,
                message: "还差一个具体时间。"
            ))
        }

        if let hit = firstHit(actionText, unverifiableMarkers) {
            issues.append(RepairIssue(
                kind: .unverifiable,
                severity: .blocking,
                message: "「\(hit)」没法验证，对方也没法知道你做没做到。换成能看见的动作。"
            ))
        }

        if actionText.isEmpty {
            issues.append(RepairIssue(
                kind: .unverifiable,
                severity: .blocking,
                message: "还差一个具体动作。"
            ))
        }

        if refusedText.isEmpty {
            issues.append(RepairIssue(
                kind: .missingRefusal,
                severity: .blocking,
                message: "这一格不能空。如果 TA 拒绝，你打算怎么办？它决定这次道歉是为了 TA，还是为了你自己好受。"
            ))
        }

        return issues
    }

    static func hasBlocking(_ issues: [RepairIssue]) -> Bool {
        issues.contains { $0.severity == .blocking }
    }
}

// MARK: - 四格骨架

/// 最后由用户自己填的四格。
///
/// 这里**不生成任何一句话**，只提供标签和顺序。
/// 示例会被照抄，空格的摩擦力刚好够让人用自己的词。
enum RepairSkeleton {
    struct Line: Identifiable {
        let id: Int
        let label: String
        let placeholder: String
    }

    static let lines: [Line] = [
        Line(id: 0, label: "我做了", placeholder: "只写动作"),
        Line(id: 1, label: "你因此失去了", placeholder: "具体的，不是「不开心」"),
        Line(id: 2, label: "这不是你的问题，是", placeholder: "想不清楚可以留白"),
        Line(id: 3, label: "我想", placeholder: "一个具体动作")
    ]

    /// 固定收尾。承担一个伦理功能：让请求可以被拒绝。
    /// 这是 NVC 里唯一值得保留的部分 —— 请求与要求的差别。
    static let closing = "，如果你现在不想，我也明白"

    /// 把四格拼成可复制的一段话。全空时返回空串。
    static func render(_ values: [String]) -> String {
        var parts: [String] = []
        for (index, line) in lines.enumerated() {
            let value = index < values.count
                ? values[index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            guard !value.isEmpty else { continue }
            if line.id == lines.count - 1 {
                parts.append(line.label + " " + value + closing)
            } else {
                parts.append(line.label + " " + value)
            }
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - 草稿

/// 五步下来要写不少字，不能因为切个页面就没了。
struct RepairDraft: Codable, Equatable {
    var action = ""
    var explanation = ""
    var losses: [String: String] = [:]
    var guess = ""
    var question = ""
    var repairWhen = ""
    var repairWhat = ""
    var ifRefused = ""
    var skeleton = ["", "", "", ""]
    /// 已经推进到第几步（0-based，对应 `RepairStep.rawValue`）。
    var stepIndex = RepairStep.action.rawValue
    /// 安全闸门的回答。`true` 表示用户害怕对方的反应。
    var fearedReaction: Bool?

    func loss(_ cell: LossCell) -> String {
        losses[cell.rawValue] ?? ""
    }

    mutating func setLoss(_ text: String, for cell: LossCell) {
        losses[cell.rawValue] = text
    }

    var lossDict: [LossCell: String] {
        var result: [LossCell: String] = [:]
        for cell in LossCell.allCases {
            result[cell] = loss(cell)
        }
        return result
    }
}

/// 单槽草稿存储。只保留最近一份 —— 这个工具的使用场景是"现在就要用"，
/// 不需要历史列表，多份反而要处理"该继续哪一份"这种问题。
enum RepairDraftStore {
    static let key = "rc.repair.draft.v1"

    static func save(_ draft: RepairDraft, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(from defaults: UserDefaults = .standard) -> RepairDraft? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RepairDraft.self, from: data)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
