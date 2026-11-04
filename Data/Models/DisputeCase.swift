//
//  DisputeCase.swift
//  RelationshipCopilot
//
//  案卷模型：一次「评理」的全部持久化状态。
//
//  命名说明：类名叫 Case 会与 Swift 关键字 `case` 冲突（需反引号），故用 DisputeCase。
//  界面上叫「案卷」，不叫「案件」——后者带审判意味。
//
//  存储策略（沿用本仓库既有模式，见 RecordingSession.analysisResultData）：
//   - 证词与第三方之见都是 `Codable` 纯结构，存成 JSON `Data?`
//   - 状态存成 `String`，强类型由 `state` 计算属性提供
//   - **不在 `@Model` 属性上加 `didSet`**（SwiftData 会重写存储属性，观察器不可靠），
//     所有写入走下面的显式方法，由方法负责校验迁移合法性
//

import SwiftData
import Foundation

@Model
final class DisputeCase {

    @Attribute(.unique) var id: UUID

    /// 一句话标题。由用户填写或从第一份证词的「发生了什么」截取。
    var title: String

    /// 评理模式（sameDevice / solo），存 rawValue。
    var modeRaw: String

    /// 流程状态，存 rawValue。**只能通过 `advance(to:)` 改**。
    var stateRaw: String

    /// A 方证词（JSON）。
    var sideAData: Data?
    /// B 方证词（JSON）。solo 模式下恒为 nil。
    var sideBData: Data?

    /// 第三方之见（JSON）。
    var verdictData: Data?

    /// 这份结果是否是**降级产物**（解析失败后并列原话，没有真正形成第三方之见）。
    ///
    /// 为什么必须持久化：降级结果与正常结果在结构上是同一种 `DisputeVerdict`，
    /// 若不单独记一个标记，重启 App 后就再也分不出来了 ——
    /// 用户会以为那段并列原话就是"评理结论"。
    /// 这一栏的存在是为了让诚实的标签**跟着数据走**，而不是跟着一次会话走。
    var isDegradedVerdict: Bool = false

    /// 可解性判定的冗余列，便于列表页排序/筛选而不必解 JSON。
    var caseKindRaw: String?

    /// 安全拦截命中的风险类型（JSON 字符串数组），nil 表示未拦截。
    var safetyConcernsData: Data?

    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?

    /// 关联的人物档案。评理对象。
    @Relationship
    var profile: Profile?

    /// 从本次评理沉淀出的承诺（可解型给出的 action 可以转成一条承诺）。
    @Relationship
    var linkedPromises: [Promise]?

    init(
        title: String,
        mode: DisputeMode,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) {
        self.id = id
        self.title = title
        self.modeRaw = mode.rawValue
        self.stateRaw = DisputeCaseState.collectingA.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: - 强类型访问

extension DisputeCase {

    var mode: DisputeMode {
        get { DisputeMode(rawValue: modeRaw) ?? .solo }
        set { modeRaw = newValue.rawValue }
    }

    var state: DisputeCaseState {
        get { DisputeCaseState(rawValue: stateRaw) ?? .collectingA }
        set { stateRaw = newValue.rawValue }
    }

    var sideA: DisputeTestimony? {
        get { Self.decode(DisputeTestimony.self, from: sideAData) }
        set {
            sideAData = Self.encode(newValue)
            updatedAt = Date()
        }
    }

    var sideB: DisputeTestimony? {
        get { Self.decode(DisputeTestimony.self, from: sideBData) }
        set {
            sideBData = Self.encode(newValue)
            updatedAt = Date()
        }
    }

    var verdict: DisputeVerdict? {
        get { Self.decode(DisputeVerdict.self, from: verdictData) }
        set {
            verdictData = Self.encode(newValue)
            caseKindRaw = newValue?.solvability.rawValue
            updatedAt = Date()
        }
    }

    var solvability: DisputeSolvability? {
        guard let raw = caseKindRaw else { return verdict?.solvability }
        return DisputeSolvability(rawValue: raw)
    }

    var safetyConcerns: [SafetyConcern] {
        get {
            guard let data = safetyConcernsData,
                  let raws = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return raws.compactMap { SafetyConcern(rawValue: $0) }
        }
        set {
            safetyConcernsData = newValue.isEmpty
                ? nil
                : try? JSONEncoder().encode(newValue.map(\.rawValue))
            updatedAt = Date()
        }
    }

    /// 已有第三方之见且可交付。
    var hasDeliverableVerdict: Bool {
        guard let verdict else { return false }
        return verdict.isDeliverable
    }

    /// 是否命中安全拦截。
    var isBlocked: Bool { state == .blocked || !safetyConcerns.isEmpty }

    /// 列表页副标题：一行说清这案子现在什么状态。
    var statusSummary: String {
        if isBlocked { return "已停止评理" }
        if let verdict {
            return verdict.solvability.displayName
        }
        return state.displayName
    }

    // MARK: 写入

    /// 状态迁移。非法迁移**静默拒绝并返回 false**，由调用方决定是否提示。
    ///
    /// 不做 `assertionFailure`：真实用户操作顺序不可控（比如快速连点），
    /// 让一次非法点击崩掉 App 是不可接受的。这里用返回值表达失败。
    @discardableResult
    func advance(to next: DisputeCaseState) -> Bool {
        guard state.canTransition(to: next, mode: mode) else { return false }
        state = next
        updatedAt = Date()
        if next == .closed, closedAt == nil {
            closedAt = Date()
        }
        return true
    }

    /// 提交某一方的证词，并把状态推进到下一步。
    ///
    /// - Parameters:
    ///   - testimony: 已完成的证词（四题填满）。
    ///   - party: 提交方。
    /// - Returns: 提交后的状态；若证词不完整或当前状态不接受该方提交，返回 nil。
    @discardableResult
    func submit(_ testimony: DisputeTestimony, by party: DisputeParty) -> DisputeCaseState? {
        guard testimony.isComplete else { return nil }

        switch (mode, party, state) {

        // 同机模式：A 写完 → 等对方
        case (.sameDevice, .a, .collectingA):
            sideA = testimony
            return advance(to: .waitingForB) ? state : nil

        // 同机模式：B 写完 → 可以看了
        case (.sameDevice, .b, .collectingB):
            sideB = testimony
            return advance(to: .ready) ? state : nil

        // 单机自省：只有一份，写完直接 ready
        case (.solo, .a, .collectingA):
            sideA = testimony
            return advance(to: .ready) ? state : nil

        default:
            return nil
        }
    }

    /// 安全拦截。凭证词扫描结果写入并把状态打到 blocked。
    func block(concerns: [SafetyConcern]) {
        guard !concerns.isEmpty else { return }
        safetyConcerns = concerns
        state = .blocked
        updatedAt = Date()
    }

    /// 重新开一次：保留证词，清掉上次结果，回到可重新生成的 ready。
    func reopenForRegeneration() {
        verdictData = nil
        caseKindRaw = nil
        isDegradedVerdict = false
        closedAt = nil
        state = .ready
        updatedAt = Date()
    }

    // MARK: JSON 工具

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }
}

// MARK: - 标题生成

extension DisputeCase {

    /// 新建时的占位标题。首份证词提交后会被替换成更具体的标题。
    static let defaultTitle = "未命名的一件"

    /// 从第一份证词推一个标题，避免列表页一片「未命名」。
    /// 只在用户没填标题时使用。
    static func suggestedTitle(from testimony: DisputeTestimony) -> String {
        let base = testimony.answer(for: .happened)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "一次没说清的事" }
        let firstSentence = base.split(whereSeparator: { "。！？\n".contains($0) }).first.map(String.init) ?? base
        let clipped = firstSentence.count > 18 ? String(firstSentence.prefix(18)) + "…" : firstSentence
        return clipped.isEmpty ? "一次没说清的事" : clipped
    }
}
