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

    /// 远程邀请的公开 id（走 URL 路径，服务端拿它当 KV 键）。
    ///
    /// 与下面的密钥分开存：这个值是**公开**的 —— 它出现在链接里、
    /// 出现在服务端日志/路由里，本身不构成秘密。
    var inviteCaseId: String?

    /// 远程邀请的密钥（base64url，32 字节）。
    ///
    /// ## 为什么存在本地数据库而不是 Keychain
    ///
    /// 它必须能跟着案卷一起"活到对方写完"，可能是几天以后。
    /// Keychain 的 `WhenUnlockedThisDeviceOnly` 在锁屏重启后会拒绝读取，
    /// 而用户完全可能锁屏一夜、第二天早上才点刷新。
    /// 存进 SwiftData 意味着它跟着案卷走：随 App 的数据一起删除，
    /// 不会在 Keychain 里留下一条谁也不记得的孤儿密钥。
    ///
    /// ## 代价必须写清楚
    ///
    /// 密钥与密文在同一台设备上 —— 拿到这台手机（或它的备份）的人，
    /// 既能读 A 的证词，也能解开 B 的。所以远程模式**不比同机模式更安全**，
    /// 它解决的是"两个人不在一处"，不是"这台手机被攻破"。
    /// 界面文案必须与这句话一致（见 `DisputeListView.privacyBody` 的 remote 分支）。
    var inviteKeyBase64URL: String?

    /// 对方那份证词的秘密已用掉（成功解密并写入 `sideBData`）。
    ///
    /// 用掉之后就把密钥清掉：一份已经解开的内容没有理由让密钥继续留在库里。
    var inviteKeyConsumed: Bool = false

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

    // MARK: 远程邀请

    /// 现有的邀请链接材料。缺任意一半都返回 nil（只有 id 没有密钥的链接是打不开的）。
    var inviteLink: InviteLink? {
        guard let caseId = inviteCaseId,
              let key = inviteKeyBase64URL,
              !caseId.isEmpty, !key.isEmpty else { return nil }
        return InviteLink(caseId: caseId, keyBase64URL: key)
    }

    /// 写入一套新的邀请材料。**只在还没有材料时调用** ——
    /// 覆盖意味着换密钥，而对方手里那条旧链接会立刻失效。
    @discardableResult
    func setInvite(_ secret: InviteSecret) -> Bool {
        guard inviteLink == nil else { return false }
        inviteCaseId = secret.caseId
        inviteKeyBase64URL = secret.keyBase64URL
        inviteKeyConsumed = false
        updatedAt = Date()
        return true
    }

    /// 对方那份已经解出来了：清掉密钥。
    ///
    /// 保留 `inviteCaseId` —— 界面还要靠它去刷新/确认状态，
    /// 而它本身不含任何秘密。
    func consumeInviteKey() {
        inviteKeyBase64URL = nil
        inviteKeyConsumed = true
        updatedAt = Date()
    }

    /// 放弃远程模式、改用同一台手机。
    ///
    /// 已收下的证词不删（那是对方写的，删掉等于替人丢掉一段话），
    /// 只把邀请材料作废 —— 让服务器上那份在 7 天后自然消失。
    func abandonInvite() {
        inviteCaseId = nil
        inviteKeyBase64URL = nil
        inviteKeyConsumed = false
        updatedAt = Date()
    }

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

        // 远程模式：A 写完 → 等对方在自己设备上写
        //
        // 这一条**必须单独列出**，不能靠上面的 `.sameDevice` 兜。
        // 这个 switch 用 tuple 匹配，`default` 返回 nil ——
        // 少了这一条，远程模式下点"提交"会静默失败（返回 nil），
        // 而界面只会显示一句含糊的"提交失败"。
        case (.remote, .a, .collectingA):
            sideA = testimony
            return advance(to: .waitingForB) ? state : nil

        // 远程模式：对方的证词从服务器取回并解出后写入
        case (.remote, .b, .collectingB):
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
