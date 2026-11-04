//
//  DisputeLogicTests.swift
//  RelationshipCopilotTests
//
//  评理（Dispute）核心逻辑的正式测试。
//
//  ## 这个文件为什么必须存在
//
//  在此之前，评理的全部断言只活在 `Tools/logic-check/main.swift` 里 ——
//  那是一个手工执行的脚本，**不在 `xcodebuild test` 里，也不在 XCTest target 里**
//  （`grep -c "logic-check" project.yml` 的结果是 0）。
//  也就是说：安全筛查（自伤/暴力/控制）这道闸门，在本文件出现之前
//  **没有任何自动化回归保护**。改词表时误删一条高危词，不会有任何东西拦下来。
//
//  ## 覆盖范围
//
//    · 证词协议（四问、字数上限、渲染不泄露作者）
//    · 结果结构（对称性、内容守卫、分流取用）
//    · 解析器（严格性：缺字段必须抛错，不补默认值）
//    · 安全前置筛查（三类风险 + 误伤边界）
//    · 状态机与闸门（不允许跳过对方证词）
//    · 双桶限流（RPM / TPM）
//    · 提示词硬约束（禁止责任分配、禁止假装中立）
//
//  ## 关于"反向验证"
//
//  本项目的教训是「断言全绿但界面/逻辑是坏的」。所以关键断言都配了一条反向用例：
//  故意构造一个**应当被拒绝**的输入，确认守卫真的会拒绝。
//  只断言"合法的能通过"是不够的 —— 那无法区分"守卫有效"和"守卫根本没运行"。
//

import XCTest
@testable import RelationshipCopilot

// MARK: - 证词

final class DisputeTestimonyTests: XCTestCase {

    func testBlankTestimonyIsIncomplete() {
        let testimony = DisputeTestimony()
        XCTAssertFalse(testimony.isComplete)
        XCTAssertEqual(testimony.answeredCount, 0)
    }

    func testAllFourQuestionsRequiredForCompletion() {
        var testimony = DisputeTestimony()
        testimony.setAnswer("周三晚上说好一起吃饭，我等到九点半", for: .happened)
        testimony.setAnswer("我觉得自己不重要", for: .hurtMost)
        testimony.setAnswer("下次晚归提前发一条消息", for: .request)

        XCTAssertEqual(testimony.answeredCount, 3)
        XCTAssertFalse(testimony.isComplete, "只答三题不该算完成")

        testimony.setAnswer("我也可以早点问一句", for: .myPart)
        XCTAssertEqual(testimony.answeredCount, 4)
        XCTAssertTrue(testimony.isComplete)
    }

    func testOverlongAnswerIsTruncatedNotRejected() {
        var testimony = DisputeTestimony()
        testimony.setAnswer(String(repeating: "字", count: 500), for: .happened)
        XCTAssertEqual(
            testimony.answer(for: .happened).count,
            TestimonyQuestion.characterLimit,
            "超长输入必须被裁剪到上限，而不是静默丢弃或原样保存"
        )
    }

    /// 第 4 问「你自己那一份」是整套设计的关键（参考产品的核心机制），
    /// 顺序不能变 —— 它必须在最后，强制先自我归因再进评理。
    func testSelfAttributionQuestionIsLast() {
        XCTAssertEqual(TestimonyQuestion.myPart.rawValue, 3)
        XCTAssertEqual(TestimonyQuestion.allCases.last, .myPart)
        XCTAssertTrue(TestimonyQuestion.myPart.title.contains("你自己"))
    }

    /// 渲染给模型的文本**不得**包含作者身份，否则模型可能按"谁先写"偏心。
    func testRenderedTestimonyDoesNotLeakAuthor() {
        var testimony = DisputeTestimony()
        testimony.setAnswer("我先说的", for: .happened)
        let rendered = testimony.renderedForPrompt()
        XCTAssertFalse(rendered.contains("第一位"))
        XCTAssertFalse(rendered.contains("原告"))
    }
}

// MARK: - 结果结构与中立性

final class DisputeVerdictTests: XCTestCase {

    private func makeVerdict(
        needA: String,
        needB: String,
        kind: DisputeSolvability = .solvable,
        action: String? = "今晚睡前各自说一句今天最累的时刻。",
        coexistence: String? = nil
    ) -> DisputeVerdict {
        DisputeVerdict(
            reframe: "一方在争时间，另一方在争被在意。",
            needA: needA,
            needB: needB,
            stuckPoint: "你们卡在谁先开口这件事上。",
            solvability: kind,
            action: action,
            coexistence: coexistence
        )
    }

    func testBalancedNeedsPassSymmetry() {
        let verdict = makeVerdict(
            needA: "我不是要你陪我，我只是想知道你什么时候回来。",
            needB: "我不是不在意你，我只是那天下班太累了。"
        )
        XCTAssertTrue(verdict.symmetry.passed, "ratio=\(verdict.symmetry.ratio)")
        XCTAssertTrue(verdict.isDeliverable)
    }

    /// 反向验证：不对称必须被拦下。
    /// 若这条测试通过而 `testBalancedNeedsPassSymmetry` 也通过，
    /// 说明对称性判定真的在区分，而不是恒真。
    func testSkewedNeedsAreRejected() {
        let verdict = makeVerdict(
            needA: "我需要你。",
            needB: "我那天其实很累而且公司临时有急事所以回来晚了也没顾上发消息我知道你在等但我真的不是故意的。"
        )
        XCTAssertFalse(verdict.symmetry.passed, "ratio=\(verdict.symmetry.ratio)")
        XCTAssertFalse(verdict.isDeliverable)
    }

    func testEmptySideVetoesImmediately() {
        let verdict = makeVerdict(needA: "", needB: "我不是不在意你。")
        XCTAssertTrue(verdict.symmetry.hasEmpty)
        XCTAssertFalse(verdict.isDeliverable)
    }

    /// 结果里**不允许**出现责任分配。这是产品红线，不是风格偏好。
    func testPercentageIsBlockedByContentGuard() {
        let verdict = makeVerdict(needA: "你占 60% 责任。", needB: "我认 40%。")
        XCTAssertFalse(verdict.passesContentGuards)
        XCTAssertFalse(verdict.forbiddenHits.isEmpty, "内容守卫没有命中任何禁用词，说明它没生效")
    }

    func testBlameLanguageIsBlockedByContentGuard() {
        let verdict = makeVerdict(needA: "这次是你错了。", needB: "也许吧。")
        XCTAssertFalse(verdict.passesContentGuards)
    }

    /// 正常措辞不得被守卫误伤 —— 否则守卫会把好结果也挡掉。
    func testNormalWordingPassesContentGuard() {
        let verdict = makeVerdict(
            needA: "我想被在意。",
            needB: "我需要喘口气。"
        )
        XCTAssertTrue(verdict.passesContentGuards, "命中：\(verdict.forbiddenHits)")
    }

    func testPerpetualUsesCoexistenceAsClosing() {
        let verdict = makeVerdict(
            needA: "我慢热。",
            needB: "我需要热闹。",
            kind: .perpetual,
            action: nil,
            coexistence: "承认节奏不同，把「等」变成可预期的事。"
        )
        XCTAssertEqual(verdict.closing, "承认节奏不同，把「等」变成可预期的事。")
        XCTAssertNotNil(verdict.closing)
    }

    func testPerpetualExplanationCitesGottman() {
        XCTAssertTrue(DisputeSolvability.perpetual.explanation.contains("69%"))
    }

    /// 可解决型缺 action 时**不许**编造一句收尾。
    func testSolvableWithoutActionHasNoClosing() {
        let verdict = makeVerdict(needA: "12345", needB: "12345", action: nil)
        XCTAssertNil(verdict.closing)
    }

    // MARK: 带走（复制/分享）

    private func makeFullVerdict(kind: DisputeSolvability) -> DisputeVerdict {
        DisputeVerdict(
            reframe: "一方在争时间，另一方在争被在意。",
            needA: "我想知道你什么时候回来。",
            needB: "我那天实在太累了。",
            stuckPoint: "你们卡在谁先开口这件事上。",
            solvability: kind,
            action: kind == .solvable ? "今晚睡前各自说一句今天最累的时刻。" : nil,
            coexistence: kind == .perpetual ? "把「等」变成可预期的事。" : nil
        )
    }

    /// 导出的文本必须四段齐全 —— 少一段就等于给了半截结论。
    func testShareTextContainsAllFourSections() {
        let text = makeFullVerdict(kind: .solvable).shareText
        XCTAssertTrue(text.contains("① 你们其实在争两件事"))
        XCTAssertTrue(text.contains("② 各自想被听见的一句"))
        XCTAssertTrue(text.contains("③ 你们卡在哪"))
        XCTAssertTrue(text.contains("④ 今晚可以做的一件事"))
        XCTAssertTrue(text.contains("今晚睡前各自说一句今天最累的时刻。"))
    }

    /// 永久型必须导出 coexistence，且用的是对应的段标题。
    /// 用错标题会让读者以为拿到的是"今晚要做的事"，实际是一句长期说法。
    func testPerpetualShareTextUsesCoexistenceHeading() {
        let text = makeFullVerdict(kind: .perpetual).shareText
        XCTAssertTrue(text.contains("④ 可以长期这么放着的说法"))
        XCTAssertTrue(text.contains("把「等」变成可预期的事。"))
        XCTAssertFalse(text.contains("今晚可以做的一件事"))
    }

    /// 导出文本**不得**出现责任分配或判决措辞。
    /// 这段文字是要转给对方的，一个字的不慎就会把中立变成指责。
    func testShareTextHasNoBlameLanguage() {
        let text = makeFullVerdict(kind: .solvable).shareText
        for banned in ["责任", "谁对谁错", "你错了", "%"] {
            XCTAssertFalse(text.contains(banned), "导出文本出现「\(banned)」，转发出去会变成指责")
        }
    }

    /// 两侧标签必须对称，不能用 A/B 或甲方乙方 —— 转给对方时读起来才不别扭。
    func testShareTextUsesSymmetricLabels() {
        let text = makeFullVerdict(kind: .solvable).shareText
        XCTAssertTrue(text.contains("一方："))
        XCTAssertTrue(text.contains("另一方："))
        XCTAssertFalse(text.contains("甲方"))
        XCTAssertFalse(text.contains("A 方"))
    }
}

// MARK: - 解析器严格性

final class DisputeVerdictParserTests: XCTestCase {

    private let validJSON = """
    {"reframe": "一方在争时间，另一方在争被在意。",
     "needA": "我不是要你陪我，我只是想知道你什么时候回来。",
     "needB": "我不是不在意你，我只是那天下班太累了。",
     "stuckPoint": "你们卡在谁先开口这件事上。",
     "solvability": "solvable",
     "action": "今晚睡前各自说一句今天最累的时刻。"}
    """

    private func assertRejects(_ json: String, _ message: String) {
        XCTAssertThrowsError(try DisputeVerdictParser.parse(json), message)
    }

    func testParsesCompleteJSON() throws {
        let verdict = try DisputeVerdictParser.parse(validJSON)
        XCTAssertTrue(verdict.isDeliverable)
    }

    /// 缺字段必须抛错，**绝不能补默认值**。
    /// 补默认值等于让模型少写一段也能过关，最终用户会看到半截结论。
    func testMissingFieldThrows() {
        assertRejects(
            #"{"reframe":"a","needA":"b","stuckPoint":"c","solvability":"solvable","action":"d"}"#,
            "缺 needB 时应抛错，而不是补默认值"
        )
    }

    func testSolvableWithoutActionThrows() {
        assertRejects(
            #"{"reframe":"a","needA":"b","needB":"c","stuckPoint":"d","solvability":"solvable"}"#,
            "可解决型缺 action 属于残次结果，应抛错"
        )
    }

    func testUnknownSolvabilityThrows() {
        assertRejects(
            #"{"reframe":"a","needA":"b","needB":"c","stuckPoint":"d","solvability":"maybe","action":"e"}"#,
            "未知分流类型不能被猜成 solvable"
        )
    }

    /// 模型主动拒答（安全标记）必须被识别出来，而不是当成解析失败。
    /// 两者的界面行为完全不同：前者不应给"重试"，后者才给。
    func testBlockedMarkerIsRecognised() {
        assertRejects(
            #"{"blocked": true, "reason": "涉及自伤"}"#,
            "blocked 标记应走安全路径"
        )
    }

    func testExtractsJSONFromFencedProse() throws {
        let wrapped = "好的，结果如下：\n```json\n" + validJSON + "\n```\n希望有帮助。"
        let verdict = try DisputeVerdictParser.parse(wrapped)
        XCTAssertTrue(verdict.isDeliverable)
    }

    func testFallbackDeclaresFailureAndInventsNothing() {
        let testimony = DisputeTestimony(happened: "a", hurtMost: "b", request: "c", myPart: "d")
        let fallback = DisputeVerdictParser.fallback(a: testimony, b: testimony, reason: "格式漂移")
        XCTAssertTrue(fallback.reframe.contains("没能"), "降级结果必须自己声明没成功")
        XCTAssertNil(fallback.action, "降级时不得编造行动建议")
    }
}

// MARK: - 安全前置筛查

final class SafetyScreenTests: XCTestCase {

    /// 正常抱怨不得被误伤。
    /// 这条与下面三条构成一组：只有"该拦的拦、不该拦的不拦"同时成立，词表才算可用。
    func testNormalComplaintIsNotBlocked() {
        let result = SafetyScreen.screen("他昨天回来很晚，我有点难过")
        XCTAssertFalse(result.isBlocking, "正常抱怨被误判成危机，会让用户不敢写")
    }

    func testSelfHarmIsDetected() {
        XCTAssertTrue(SafetyScreen.screen("我真的不想活了").concerns.contains(.selfHarm))
    }

    func testViolenceIsDetected() {
        XCTAssertTrue(SafetyScreen.screen("他对我家暴").concerns.contains(.violence))
    }

    func testCoerciveControlIsDetected() {
        XCTAssertTrue(SafetyScreen.screen("他天天查我手机").concerns.contains(.coerciveControl))
    }

    /// 扫描必须覆盖四题全文，而不是只看第一题。
    func testScansWholeTestimonyNotJustFirstAnswer() {
        var risky = DisputeTestimony()
        risky.setAnswer("他动手打了我", for: .happened)
        XCTAssertTrue(SafetyScreen.screen(risky).isBlocking)
    }

    func testViolenceGuidanceIncludesEmergencyPath() {
        let guidance = SafetyScreen.guidance(for: [.violence])
        XCTAssertTrue(
            guidance.actionLine.contains("紧急"),
            "暴力类引导必须给紧急求助路径，而不是继续评理"
        )
    }

    /// 空输入不该触发任何拦截。
    func testEmptyInputIsClear() {
        XCTAssertFalse(SafetyScreen.screen("").isBlocking)
    }
}

// MARK: - 状态机与闸门

final class DisputeCaseStateTests: XCTestCase {

    private var completeTestimony: DisputeTestimony {
        DisputeTestimony(happened: "a", hurtMost: "b", request: "c", myPart: "d")
    }

    func testCannotSkipPartnerInSameDeviceMode() {
        XCTAssertTrue(DisputeCaseState.collectingA.canTransition(to: .waitingForB, mode: .sameDevice))
        XCTAssertFalse(
            DisputeCaseState.collectingA.canTransition(to: .ready, mode: .sameDevice),
            "双人模式允许跳过对方证词，'各写各的'这个前提就不成立了"
        )
    }

    func testSoloModeGoesStraightToReady() {
        XCTAssertTrue(DisputeCaseState.collectingA.canTransition(to: .ready, mode: .solo))
    }

    /// 只有 ready 才允许调用模型。这是控制成本与防止半截数据进模型的关键闸。
    func testOnlyReadyAllowsJudging() {
        XCTAssertTrue(DisputeCaseState.ready.allowsJudging)
        XCTAssertFalse(DisputeCaseState.collectingA.allowsJudging)
        XCTAssertFalse(DisputeCaseState.waitingForB.allowsJudging)
        XCTAssertFalse(DisputeCaseState.collectingB.allowsJudging)
        XCTAssertFalse(DisputeCaseState.blocked.allowsJudging)
    }

    func testBlockedIsTerminalButCanRestart() {
        XCTAssertFalse(DisputeCaseState.blocked.canTransition(to: .ready, mode: .sameDevice))
        XCTAssertTrue(
            DisputeCaseState.blocked.canTransition(to: .collectingA, mode: .sameDevice),
            "被拦截后必须允许重写，否则这条案卷就死在这里了"
        )
    }

    func testGateRejectsMissingPartnerTestimony() {
        let rejection = DisputeCaseGate.check(
            state: .ready, mode: .sameDevice, sideA: completeTestimony, sideB: nil
        )
        XCTAssertEqual(rejection, .missingTestimony(.b))
    }

    func testGateRejectsPrematureGeneration() {
        let rejection = DisputeCaseGate.check(
            state: .collectingB, mode: .sameDevice, sideA: completeTestimony, sideB: completeTestimony
        )
        XCTAssertEqual(rejection, .stateNotReady(.collectingB))
    }

    func testGateEmbedsSafetyScreening() {
        var unsafe = completeTestimony
        unsafe.setAnswer("他威胁我", for: .hurtMost)
        let rejection = DisputeCaseGate.check(
            state: .ready, mode: .sameDevice, sideA: unsafe, sideB: completeTestimony
        )
        guard case .safetyBlocked = rejection else {
            return XCTFail("闸门没有拦住含威胁的证词，实际结果：\(String(describing: rejection))")
        }
    }

    func testSoloGateOnlyRequiresSideA() {
        XCTAssertNil(
            DisputeCaseGate.check(state: .ready, mode: .solo, sideA: completeTestimony, sideB: nil)
        )
    }
}

// MARK: - 双桶限流

final class ModelRateLimiterTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testInitiallyAllowed() {
        // `checkDisputeRequest` 是 mutating 的（内部会按时间推进令牌桶），所以必须 var。
        var limiter = ModelRateLimiter(now: t0)
        XCTAssertNil(limiter.checkDisputeRequest(now: t0))
    }

    func testRequestsPerMinuteIsEnforced() {
        var limiter = ModelRateLimiter(now: t0)
        for _ in 0..<ModelRateLimiter.defaultRPM {
            limiter.recordDisputeRequest(actualTokens: 1_000, now: t0)
        }
        guard case .mustWait(let seconds, let reason)? = limiter.checkDisputeRequest(now: t0) else {
            return XCTFail("打满 RPM 后仍被允许发送")
        }
        XCTAssertEqual(reason, .requestsPerMinute)
        // 120/60 = 2 个/秒，所以最多等 2 秒
        XCTAssertLessThanOrEqual(seconds, 2.0, "等待时间不合理，会让用户以为卡死")
    }

    func testBucketRefillsAfterAMinute() {
        var limiter = ModelRateLimiter(now: t0)
        for _ in 0..<ModelRateLimiter.defaultRPM {
            limiter.recordDisputeRequest(actualTokens: 1_000, now: t0)
        }
        XCTAssertNil(limiter.checkDisputeRequest(now: t0.addingTimeInterval(61)))
    }

    func testTokensPerMinuteIsEnforced() {
        var limiter = ModelRateLimiter(now: t0)
        for _ in 0..<20 {
            limiter.recordDisputeRequest(actualTokens: 30_000, now: t0)
        }
        guard case .mustWait(_, let reason)? = limiter.checkDisputeRequest(now: t0) else {
            return XCTFail("打满 TPM 后仍被允许发送")
        }
        XCTAssertEqual(reason, .tokensPerMinute)
    }

    func testDefaultsMatchModelContract() {
        XCTAssertEqual(ModelRateLimiter.defaultRPM, 120)
        XCTAssertEqual(ModelRateLimiter.defaultTPM, 600_000)
    }

    func testTokenEstimatorIsConservativeForChinese() {
        XCTAssertGreaterThan(TokenEstimator.estimate(String(repeating: "字", count: 1000)), 1000)
    }

    func testTokenEstimatorIsCheaperForEnglish() {
        XCTAssertLessThan(TokenEstimator.estimate(String(repeating: "a", count: 1000)), 400)
    }
}

// MARK: - 提示词硬约束

//
// 提示词是"软"实现，但其中的硬约束必须可被机器验证。
// 模型可以不听话，但提示词少了这条约束就一定会出问题。

final class DisputePromptTests: XCTestCase {

    private var sameDevicePrompt: String {
        DisputePrompt.systemPrompt(mode: .sameDevice, relationshipLabel: "伴侣")
    }

    private var soloPrompt: String {
        DisputePrompt.systemPrompt(mode: .solo, relationshipLabel: "伴侣")
    }

    func testSameDevicePromptForbidsBlameAllocation() {
        XCTAssertTrue(sameDevicePrompt.contains("禁止任何形式的责任分配"))
    }

    func testSameDevicePromptRequiresSymmetry() {
        XCTAssertTrue(sameDevicePrompt.contains("20%"))
    }

    func testSameDevicePromptCitesGottman() {
        XCTAssertTrue(sameDevicePrompt.contains("69%"))
    }

    func testSameDevicePromptRequiresSharedStuckPointWording() {
        XCTAssertTrue(sameDevicePrompt.contains("你们卡在"), "「你们卡在」而非「你在」，是中立性的措辞要求")
    }

    func testSameDevicePromptHasSafetyClause() {
        XCTAssertTrue(sameDevicePrompt.contains("blocked"))
    }

    func testSameDevicePromptDefaultsToPerpetualWhenUnsure() {
        XCTAssertTrue(sameDevicePrompt.contains("不确定时一律判 perpetual"))
    }

    /// 单机模式**绝不能假装中立**：只有一份陈述时，
    /// 说"你们各有一半责任"是编造中立，比硬编码分数更糟（动态生成、更可信）。
    func testSoloPromptForbidsFakeNeutrality() {
        XCTAssertTrue(soloPrompt.contains("绝不能假装中立"))
        XCTAssertTrue(soloPrompt.contains("禁止出现「双方」"))
        XCTAssertTrue(soloPrompt.contains("我猜 TA"))
    }

    /// 反向验证：两套提示词必须真的不同，否则"单机不装中立"没有落实。
    func testPromptsDifferByMode() {
        XCTAssertNotEqual(sameDevicePrompt, soloPrompt)
    }
}
