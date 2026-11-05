//
//  DisputeFlowModel.swift
//  RelationshipCopilot
//
//  评理流程的视图模型。**所有业务判断都在 Core 层**，这里只做三件事：
//   ① 持有正在编辑的草稿（草稿绝不落盘 —— 落盘就等于对方可能看到）
//   ② 把用户操作翻译成状态迁移
//   ③ 调服务、收结果
//
//  为什么草稿不落盘：
//  同机模式的数据全在同一台手机上，"密封"只能是界面级。
//  但界面级密封也分强弱 —— 如果 A 的草稿写一半就被 SwiftData 持久化，
//  那么即使界面不显示，它也已经存在于本地数据库、存在于任何一次 iCloud 备份里。
//  只让**已提交**的证词落盘，是这套设计里唯一能兑现的承诺。
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class DisputeFlowModel {

    // MARK: 输入

    let mode: DisputeMode
    private(set) var state: DisputeCaseState

    /// 正在书写的草稿。提交后清空。
    var draft = DisputeTestimony()

    /// 当前聚焦的问题（用于自动滚动与焦点管理）。
    var focusedQuestion: TestimonyQuestion?

    // MARK: 输出

    private(set) var isGenerating = false
    private(set) var outcome: DisputeOutcome?
    private(set) var error: AppError?

    /// 上一次提交失败的原因（比如证词没填满）。
    var submissionHint: String?

    /// 安全引导（命中风险时非 nil）。
    var safetyGuidance: SafetyGuidance? {
        if case .blocked(let guidance) = outcome { return guidance }
        return nil
    }

    private let service: DisputeEvaluating

    /// 邀请服务。远程模式才用到；其他模式注入 nil 也没关系。
    ///
    /// `var` 而不是 `let`：地址在视图的 `.task` 里才解析出来（它要读 Info.plist
    /// 与 Keychain），而模型在那之前已经构造好了。允许视图把解析结果回填进来，
    /// 保证"拼链接用的地址"和"发请求用的地址"是同一个 ——
    /// 这两者一旦分叉，界面上表现为链接正常显示但一点刷新就报配置错误。
    var inviteService: InviteServicing

    // 注意：这里刻意**不**写 `service: DisputeEvaluating = AIService.shared`。
    // 默认参数表达式在调用方的非隔离上下文求值，而 `AIService` 是 @MainActor 的，
    // 会触发 "main actor-isolated static property 'shared' can not be referenced
    // from a nonisolated context"（Swift 6 下是错误）。改为在本类的 @MainActor
    // init 体内解析默认值。
    init(
        mode: DisputeMode,
        state: DisputeCaseState,
        service: DisputeEvaluating? = nil,
        inviteService: InviteServicing? = nil
    ) {
        self.mode = mode
        self.state = state
        self.service = service ?? AIService.shared
        self.inviteService = inviteService ?? InviteService()
    }

    /// 由已存在的案卷恢复。
    convenience init(
        case disputeCase: DisputeCase,
        service: DisputeEvaluating? = nil,
        inviteService: InviteServicing? = nil
    ) {
        self.init(
            mode: disputeCase.mode,
            state: disputeCase.state,
            service: service,
            inviteService: inviteService
        )
        if disputeCase.isBlocked {
            self.outcome = .blocked(SafetyScreen.guidance(for: disputeCase.safetyConcerns))
        } else if let verdict = disputeCase.verdict {
            // 从持久化的降级标记恢复，而不是一律当成 `.verdict`。
            // 少了这一步，重启 App 后降级结果会长得和正常结果一模一样。
            self.outcome = disputeCase.isDegradedVerdict
                ? .fallback(verdict, reason: "解析失败，已并列原话")
                : .verdict(verdict)
        }
    }

    // MARK: 派生状态

    /// 当前应该展示给谁写。
    var currentAuthor: DisputeParty? {
        switch state {
        case .collectingA: return .a
        case .collectingB: return .b
        default:           return nil
        }
    }

    /// 当前是否允许编辑。
    var isEditable: Bool { currentAuthor != nil }

    /// 提交按钮是否可用。**本地预检，不发请求**。
    var canSubmit: Bool {
        isEditable && draft.isComplete
    }

    var answeredCount: Int { draft.answeredCount }
    var totalQuestions: Int { TestimonyQuestion.allCases.count }

    /// 是否到了可以看结果的时刻。
    var canGenerate: Bool { state.allowsJudging }

    /// 进度条用的 0...1。
    var progress: Double {
        let per = 0.25
        switch state {
        case .collectingA: return Double(answeredCount) / Double(totalQuestions) * per
        case .waitingForB: return 0.25
        case .collectingB: return 0.25 + Double(answeredCount) / Double(totalQuestions) * per
        case .ready:       return 1
        case .closed, .blocked: return 1
        }
    }

    // MARK: 操作

    /// 提交当前草稿。成功后清空草稿 —— 这一步是密封的关键：
    /// 下一个写的人面对的是一个完全空白、没有任何残影的表单。
    @discardableResult
    func submit(to disputeCase: DisputeCase, context: ModelContext) -> Bool {
        guard let party = currentAuthor else { return false }
        guard draft.isComplete else {
            submissionHint = "还有 \(totalQuestions - answeredCount) 个问题没写。"
            return false
        }

        guard let next = disputeCase.submit(draft, by: party) else {
            submissionHint = "现在不能提交。"
            return false
        }

        // 首份证词提交时顺手推一个标题，避免列表里一片「未命名的一件」。
        if party == .a, disputeCase.title == DisputeCase.defaultTitle {
            disputeCase.title = DisputeCase.suggestedTitle(from: draft)
        }

        // 本地安全筛查：命中即拦，省一次模型调用
        let screening = SafetyScreen.screen(draft)
        if screening.isBlocking {
            disputeCase.block(concerns: screening.concerns)
            state = .blocked
            outcome = .blocked(SafetyScreen.guidance(for: screening.concerns))
            draft = DisputeTestimony()
            save(context)
            return true
        }

        state = next
        draft = DisputeTestimony()
        focusedQuestion = nil
        submissionHint = nil
        save(context)
        return true
    }

    /// 从「等对方」进到「对方在写」。设备交接的唯一入口。
    func handOver(to disputeCase: DisputeCase, context: ModelContext) {
        guard disputeCase.advance(to: .collectingB) else { return }
        state = .collectingB
        draft = DisputeTestimony()
        save(context)
    }

    /// 退回让上一个人重写（递错设备时用）。
    func returnToPreviousAuthor(_ disputeCase: DisputeCase, context: ModelContext) {
        guard disputeCase.advance(to: .collectingA) else { return }
        state = .collectingA
        draft = DisputeTestimony()
        save(context)
    }

    // MARK: 远程邀请

    /// 邀请的服务端状态。nil = 还没查过。
    private(set) var inviteStatus: InviteStatus?

    /// 正在查询对方进度。
    private(set) var isRefreshingInvite = false

    /// 邀请相关的错误（与 `error` 分开：这个只影响交接屏，不该弹成全局告警）。
    private(set) var inviteErrorMessage: String?

    /// 已经连续查了几次还是没看到对方那份。
    ///
    /// KV 是最终一致的，读写之间最长约 60 秒延迟。所以"查不到"绝不能直接
    /// 判定"对方没写"—— 那会让用户以为对方放鸽子，而内容其实已经在服务器上了。
    /// 这里记录次数，界面据此把文案从"还没写"软化成"刚提交的话可能要等一会儿"。
    private(set) var invitePollCount = 0

    /// 生成（或复用）邀请链接。
    ///
    /// 幂等：已有材料就直接返回，不换密钥 ——
    /// 换一次密钥等于让对方手里那条链接作废，而用户完全可能只是切了个后台再回来。
    func ensureInviteLink(for disputeCase: DisputeCase, context: ModelContext) -> InviteLink? {
        if let existing = disputeCase.inviteLink { return existing }

        let (secret, _) = InviteSecret.generate()
        guard disputeCase.setInvite(secret) else { return disputeCase.inviteLink }
        save(context)
        Telemetry.shared.track(.disputeInviteCreated)
        return disputeCase.inviteLink
    }

    /// 查询对方进度；若对方已写完，顺手解密并写入 B 侧。
    ///
    /// - Returns: 对方那份是否已经成功取回并写入。
    @discardableResult
    func refreshInvite(for disputeCase: DisputeCase, context: ModelContext) async -> Bool {
        guard let link = disputeCase.inviteLink else {
            inviteErrorMessage = "这个邀请没有生成成功。"
            return false
        }
        guard !isRefreshingInvite else { return false }

        isRefreshingInvite = true
        inviteErrorMessage = nil
        defer { isRefreshingInvite = false }

        do {
            let status = try await inviteService.fetchStatus(caseId: link.caseId)
            inviteStatus = status

            guard let ciphertext = status.testimonies["b"] else {
                // 还没写。注意这**不代表**对方没写过 —— KV 可能还没同步到。
                //
                // 只有"查到了、但对方那份还没到"才计数。对方已写完的那次不计数，
                // 因为那时界面显示的是「可以看结果了」，跟这个计数无关；
                // 而查询本身失败（网络错误等）也不该计数 —— 那种情况
                // 我们根本不知道对方写没写，凭它去软化文案等于编造信息。
                invitePollCount += 1
                return false
            }

            // 已写过但密钥已被用掉（重复刷新）：认为已完成，不必再解一次。
            guard let keyBase64 = disputeCase.inviteKeyBase64URL else {
                return disputeCase.sideB != nil
            }

            let key = try InviteCrypto.key(fromBase64URL: keyBase64)
            let payload = try InviteCrypto.openPayload(ciphertext, key: key)

            guard let testimony = payload.toTestimony() else {
                let missing = payload.missingQuestions()
                inviteErrorMessage = missing.isEmpty
                    ? "TA 那一份的内容读不出来。"
                    : "TA 那一份还缺 \(missing.count) 题（\(missing.map(\.title).joined(separator: "、"))），请让 TA 重写一次。"
                return false
            }

            // 走正式提交路径，而不是直接写 sideB ——
            // 这样状态机、安全筛查、标题生成全部与同机模式共用一套逻辑。
            // 远程模式此时必须是 `collectingB`：A 提交后停在 `waitingForB`，
            // 而对方的证词到达就是"进入 B 已写"的触发点。
            if disputeCase.state == .waitingForB {
                _ = disputeCase.advance(to: .collectingB)
                state = .collectingB
            }

            guard disputeCase.submit(testimony, by: .b) != nil else {
                inviteErrorMessage = "TA 那一份没法写入这件案卷。"
                return false
            }
            state = disputeCase.state
            disputeCase.consumeInviteKey()
            save(context)
            Telemetry.shared.track(.disputeInviteReceived)
            return true
        } catch let appError as AppError {
            inviteErrorMessage = appError.errorDescription
            return false
        } catch let serviceError as InviteServiceError {
            inviteErrorMessage = serviceError.errorDescription
            return false
        } catch let payloadError as InvitePayloadError {
            inviteErrorMessage = payloadError.errorDescription
            return false
        } catch let urlError as URLError {
            // 不能把 `error.localizedDescription` 直接给用户看。
            //
            // 截图里实测过：网络不通时这一句是英文的
            // 「A server with the specified hostname could not be found.」
            // —— 在一个全中文、且此刻用户正在焦虑"对方能不能收到"的界面上，
            // 突然弹出系统英文报错，既看不懂也不知道该怎么办。
            inviteErrorMessage = Self.message(for: urlError)
            return false
        } catch {
            inviteErrorMessage = "暂时连不上，请检查网络后再试一次。"
            return false
        }
    }

    /// 把 `URLError` 翻成一句能指导动作的中文。
    ///
    /// 只区分"能自己解决"和"等一会儿再试"两类 —— 给用户诊断码没有意义，
    /// 他需要知道的是现在就放弃还是重试。
    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "现在没有网络。连上之后再点「刷新看看」，TA 写的内容不会丢。"
        case .timedOut:
            return "这次请求超时了。过一会儿再点「刷新看看」。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "连不上服务端。可以先用「同一台手机」的方式继续。"
        default:
            return "暂时连不上，请稍后再试。也可以先用「同一台手机」的方式。"
        }
    }

    /// 放弃远程模式，改用同一台手机继续。
    ///
    /// 这里**不重置 sideA** —— A 已经写过的那份是劳动成果，
    /// 退回只是换一种收集方式，不是让他重写。
    /// 状态回到 `collectingA`，并把已落盘的证词填回草稿，
    /// 用户点一次"提交"就会重新走到 `waitingForB`，那时走同机模式的递手机界面。
    func switchToSameDevice(_ disputeCase: DisputeCase, context: ModelContext) {
        guard disputeCase.mode == .remote else { return }
        disputeCase.abandonInvite()
        Telemetry.shared.track(.disputeInviteAbandoned)

        // 先把模式拨回去再迁移：`advance` 内部按 `mode` 判断合法性，
        // 顺序反了会让 `.remote` 下的 `.collectingA` 目标被拒。
        disputeCase.mode = .sameDevice
        guard disputeCase.advance(to: .collectingA) else {
            save(context)
            return
        }
        state = .collectingA
        draft = disputeCase.sideA ?? DisputeTestimony()
        invocationRestoredDraft = disputeCase.sideA != nil
        save(context)
    }

    /// 退回同机模式时，草稿是从已提交的 sideA 恢复的（不是用户重新打的字）。
    /// 界面据此提示"你的那份还在，确认一下再交"。
    private(set) var invocationRestoredDraft = false

    /// 生成第三方之见。
    func generate(for disputeCase: DisputeCase, context: ModelContext) async {
        guard !isGenerating else { return }
        guard let sideA = disputeCase.sideA else {
            error = .malformedAIResponse("缺少证词")
            return
        }

        // 与 UI 按钮共用同一个闸门判断，避免"能点但不能跑"
        if let rejection = DisputeCaseGate.check(
            state: disputeCase.state,
            mode: mode,
            sideA: sideA,
            sideB: disputeCase.sideB
        ) {
            if case .safetyBlocked(let concerns) = rejection {
                disputeCase.block(concerns: concerns)
                state = .blocked
                outcome = .blocked(SafetyScreen.guidance(for: concerns))
                save(context)
            } else {
                error = .malformedAIResponse(rejection.message)
            }
            return
        }

        isGenerating = true
        error = nil
        defer { isGenerating = false }

        let request = DisputeRequest(
            mode: mode,
            relationshipLabel: disputeCase.profile?.relationship.displayName ?? "重要的人",
            sideA: sideA,
            sideB: disputeCase.sideB
        )

        do {
            let result = try await service.evaluate(request)
            outcome = result

            switch result {
            case .verdict(let verdict), .fallback(let verdict, _):
                disputeCase.verdict = verdict
                // 降级标记必须跟着数据落盘：否则重启后这段"并列原话"
                // 会被当成正常的第三方之见显示，等于把一次失败伪装成成功。
                if case .fallback = result {
                    disputeCase.isDegradedVerdict = true
                }
                disputeCase.advance(to: .closed)
                state = .closed
            case .blocked(let guidance):
                disputeCase.block(concerns: guidance.concerns)
                state = .blocked
            }
            save(context)
            Telemetry.shared.track(.disputeEvaluated)
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .fromNetwork(error)
        }
    }

    /// 重新生成：保留两份证词，清掉上次结果。
    func regenerate(for disputeCase: DisputeCase, context: ModelContext) async {
        disputeCase.reopenForRegeneration()
        state = .ready
        await generate(for: disputeCase, context: context)
    }

    // MARK: 沉淀为承诺

    /// 已经沉淀出的承诺（非 nil 时按钮改为"已添加"）。
    private(set) var createdPromise: Promise?

    /// 把可解决型结果里的 `action` 变成一条可打卡的承诺。
    ///
    /// ## 这一步为什么存在
    ///
    /// 定位文档里本产品相对参考产品的唯一结构性差异，是「判决 → 承诺 → 打卡」的闭环：
    /// 参考产品判决即终止，没有留存机制；本产品可以把它变成明天能做的事。
    /// 在此之前这条链是**断的** —— `linkedPromises` 字段定义了却全库 0 处写入，
    /// AI 给出的那条具体动作看完就没了。
    ///
    /// ## 边界
    ///
    /// 只有 `verdict.canBecomePromise` 为真才允许调用（可解决型 + 有非空 action）。
    /// 永久型的共存说法不转承诺 —— 理由见 `DisputeVerdict.canBecomePromise` 的注释。
    @discardableResult
    func adoptAsPromise(for disputeCase: DisputeCase, context: ModelContext) -> Promise? {
        // 幂等：重复点击不产生第二条承诺
        if let createdPromise { return createdPromise }

        guard let verdict = disputeCase.verdict, verdict.canBecomePromise, let action = verdict.action else {
            return nil
        }

        let promise = Promise(
            content: action,
            promisor: "user",
            promisee: disputeCase.profile?.name ?? "TA"
        )
        promise.profile = disputeCase.profile
        // 来源可追溯：这条承诺是从哪一次争执里长出来的。
        // 不设 deadline —— 结果页说的是"本周找一次"，强加具体日期是替用户做决定。
        promise.commitmentType = "behavior_change"
        context.insert(promise)

        var linked = disputeCase.linkedPromises ?? []
        linked.append(promise)
        disputeCase.linkedPromises = linked

        save(context)
        createdPromise = promise
        // 记专用事件而不是 promiseCreated：这里要衡量的是"闭环转化率"，
        // 混进通用事件就再也看不出这条链通不通。
        Telemetry.shared.track(.disputeAdoptedAsPromise)
        return promise
    }

    /// 从已持久化的关联恢复"是否已添加过"的状态。
    /// 没有这一步，重启 App 后按钮会重新变成"添加"，用户会重复添加。
    func restoreAdoptedState(from disputeCase: DisputeCase) {
        createdPromise = disputeCase.linkedPromises?.first
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Dispute save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
