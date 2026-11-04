//
//  GuidedRepairTests.swift
//  RelationshipCopilotTests
//
//  引导式道歉的规则测试。
//
//  写这些测试的理由很具体：这套流程的价值全在"能不能真的拦下"。
//  如果「她不开心」不被判为抽象、如果「以后注意」不被判为不可验证，
//  那整个引导就退化成一层好看的皮，用户照样写出一段敷衍的道歉。
//
//  所以每条规则都配一个**应该被拦**的样本和一个**应该放行**的样本。
//  只测前者无法区分"规则有效"和"规则把什么都拦了"。
//

import XCTest
@testable import RelationshipCopilot

final class GuidedRepairActionTests: XCTestCase {

    func testExcuseMarkerIsSurfacedButNotBlocking() {
        let issues = RepairLinter.lintAction("我答应了六点去接她，但是那天临时开会，所以晚了两小时")
        XCTAssertTrue(issues.contains { $0.kind == .excuse }, "「但是」没有被识别为解释")
        XCTAssertFalse(
            RepairLinter.hasBlocking(issues),
            "解释不该被拦下 —— 设计上只是把它挪到第 2 步，不是禁止用户说"
        )
    }

    func testBlameShiftIsDetected() {
        let issues = RepairLinter.lintAction("我语气是不好，但她先骂我的")
        XCTAssertTrue(issues.contains { $0.kind == .blameShift }, "「她先」没有被识别为拉第二个人进来")
    }

    func testAbsoluteQuantifierIsDetected() {
        let issues = RepairLinter.lintAction("我每次都忘记回她消息，这次也是这样")
        XCTAssertTrue(issues.contains { $0.kind == .absolute }, "「每次」没有被识别")
    }

    func testEvaluationOnlyIsBlocking() {
        let issues = RepairLinter.lintAction("我态度不好")
        XCTAssertTrue(
            issues.contains { $0.kind == .vagueAction && $0.severity == .blocking },
            "「态度不好」是评价不是动作，必须拦住 —— 否则用户会以为这样就算写完了"
        )
    }

    func testConcreteActionPasses() {
        let issues = RepairLinter.lintAction("我答应了六点去接她，然后跟同事去喝酒了，手机静音，没接她三个电话")
        XCTAssertFalse(RepairLinter.hasBlocking(issues), "具体动作被误拦：\(issues)")
    }

    func testEmptyInputProducesNoNoise() {
        XCTAssertTrue(RepairLinter.lintAction("").isEmpty, "空输入不该立刻弹一堆提示吓人")
    }
}

final class GuidedRepairExplanationTests: XCTestCase {

    func testSoThatConstructionIsFlagged() {
        let issues = RepairLinter.lintExplanation("我那天太累了，所以才没回她")
        XCTAssertTrue(issues.contains { $0.kind == .excuse }, "「所以才」没有被识别为把原因当理由")
    }

    func testHelplessnessNarrativeIsFlagged() {
        let issues = RepairLinter.lintExplanation("我真的没办法，领导临时叫住我")
        XCTAssertTrue(issues.contains { $0.kind == .excuse })
    }

    func testPullingInSecondPersonIsBlocking() {
        let issues = RepairLinter.lintExplanation("我承认我错了，可你也一直不回我消息")
        XCTAssertTrue(
            issues.contains { $0.kind == .blameShift && $0.severity == .blocking },
            "这一步把第二个人拉进来必须拦住 —— 这是唯一会让整段道歉失效的东西"
        )
    }

    func testPlainExplanationPasses() {
        let issues = RepairLinter.lintExplanation("我把和同事喝酒排在了接她前面，当时觉得她会等")
        XCTAssertFalse(RepairLinter.hasBlocking(issues))
    }
}

final class GuidedRepairLossTests: XCTestCase {

    func testAbstractEmotionIsBlocking() {
        let issues = RepairLinter.lintLoss("她不开心")
        XCTAssertTrue(
            issues.contains { $0.kind == .abstractEmotion && $0.severity == .blocking },
            "「不开心」是情绪的词不是损失 —— 这一条如果失效，整个 Step 3 就没有意义了"
        )
    }

    func testConcreteLossPasses() {
        let issues = RepairLinter.lintLoss("她妈在客厅，她被我那句话堵得没再说下去")
        XCTAssertFalse(RepairLinter.hasBlocking(issues), "具体损失被误拦：\(issues)")
    }

    func testMindReadingIsWarned() {
        let issues = RepairLinter.lintLoss("她一定觉得我不在乎她")
        XCTAssertTrue(issues.contains { $0.kind == .mindReading })
    }

    func testAllEmptyLocksTheGate() {
        var draft = RepairDraft()
        draft.setLoss("", for: .dignity)
        draft.setLoss("", for: .notYourFault)
        XCTAssertFalse(
            RepairLinter.hasSubstantiveLoss(draft.lossDict),
            "七格全空却放行 —— 那么后面写出来的道歉必然还是「对不起让你不开心」"
        )
    }

    func testOnlyAbstractEmotionLocksTheGate() {
        var draft = RepairDraft()
        // 故意写得够长：短句会被长度规则拦下，那样这条测试就分不清
        // "抽象情绪被识别"和"字数不够"这两件完全不同的事。
        draft.setLoss("她很不开心，饭也没吃完就回房了", for: .dignity)
        XCTAssertFalse(
            RepairLinter.hasSubstantiveLoss(draft.lossDict),
            "一整句话只有情绪没有损失，仍然不算写到了"
        )
    }

    func testOneConcreteCellOpensTheGate() {
        var draft = RepairDraft()
        draft.setLoss("她后来问我，是不是她太计较", for: .notYourFault)
        XCTAssertTrue(RepairLinter.hasSubstantiveLoss(draft.lossDict))
    }

    func testHonestUncertaintyCounts() {
        var draft = RepairDraft()
        draft.setLoss("我不知道她当时最在意什么", for: .unsaid)
        XCTAssertTrue(
            RepairLinter.hasSubstantiveLoss(draft.lossDict),
            "「我不知道」必须算写到了 —— 这是诚实，不是敷衍。拦掉它等于逼用户编"
        )
    }
}

final class GuidedRepairPerspectiveTests: XCTestCase {

    func testClosedQuestionIsBlocking() {
        let issues = RepairLinter.lintQuestion("你是不是觉得我不在乎你？")
        XCTAssertTrue(
            issues.contains { $0.kind == .closedQuestion && $0.severity == .blocking },
            "封闭式问句是在让对方确认自己的猜测，必须拦住"
        )
    }

    func testOpenQuestionPasses() {
        let issues = RepairLinter.lintQuestion("那天我说那句话的时候，你是什么感觉？")
        XCTAssertFalse(RepairLinter.hasBlocking(issues), "开放问句被误拦：\(issues)")
    }

    func testNonQuestionIsBlocking() {
        let issues = RepairLinter.lintQuestion("我想跟她聊聊")
        XCTAssertTrue(issues.contains { $0.kind == .missingQuestion })
    }

    func testAbsoluteGuessIsWarned() {
        let issues = RepairLinter.lintGuess("他一定觉得我看不起他")
        XCTAssertTrue(issues.contains { $0.kind == .mindReading })
    }
}

final class GuidedRepairActionPlanTests: XCTestCase {

    func testVagueTimeIsBlocking() {
        let issues = RepairLinter.lintRepairAction(
            time: "改天",
            action: "跟她好好聊聊",
            ifRefused: "那我再等等"
        )
        XCTAssertTrue(issues.contains { $0.kind == .vagueTime && $0.severity == .blocking })
    }

    func testUnverifiablePromiseIsBlocking() {
        let issues = RepairLinter.lintRepairAction(
            time: "这周三晚饭后",
            action: "以后注意",
            ifRefused: "那我先不说了"
        )
        XCTAssertTrue(
            issues.contains { $0.kind == .unverifiable && $0.severity == .blocking },
            "「以后注意」没法验证 —— 不拦的话这就是一句空话"
        )
    }

    func testEmptyRefusalIsBlocking() {
        let issues = RepairLinter.lintRepairAction(
            time: "这周三晚饭后",
            action: "把那天的饭补上，去她想去的那家",
            ifRefused: ""
        )
        XCTAssertTrue(
            issues.contains { $0.kind == .missingRefusal },
            "这一格决定道歉是为了对方还是为了自己好受，不能空着"
        )
    }

    func testCompletePlanPasses() {
        let issues = RepairLinter.lintRepairAction(
            time: "这周三晚饭后",
            action: "把那天的饭补上，去她想去的那家",
            ifRefused: "那我就先不打扰她，过两天再问一次"
        )
        XCTAssertFalse(RepairLinter.hasBlocking(issues), "完整方案被误拦：\(issues)")
    }
}

final class RepairSkeletonTests: XCTestCase {

    func testEmptySkeletonRendersNothing() {
        XCTAssertEqual(RepairSkeleton.render(["", "", "", ""]), "")
    }

    func testSkeletonKeepsOrderAndAddsClosing() {
        let text = RepairSkeleton.render([
            "答应去接她，结果去喝酒了",
            "白等了三个小时",
            "我把它排在了后面",
            "这周三把饭补上"
        ])
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4, "四格应该拼成四行：\(text)")
        XCTAssertTrue(lines[0].hasPrefix("我做了"))
        XCTAssertTrue(lines[1].hasPrefix("你因此失去了"))
        XCTAssertTrue(
            lines[3].hasSuffix(RepairSkeleton.closing),
            "收尾必须包含「如果你现在不想，我也明白」—— 它承担让请求可以被拒绝的功能"
        )
    }

    func testSkippedFieldDoesNotLeaveEmptyLine() {
        let text = RepairSkeleton.render(["我摔了门", "", "", "想跟你说声对不起"])
        XCTAssertFalse(text.contains("\n\n"), "空的那格不该留下空行：\(text)")
        XCTAssertEqual(text.components(separatedBy: "\n").count, 2)
    }
}

final class RepairDraftPersistenceTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "rc.tests.repair.draft"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRoundTrip() {
        var draft = RepairDraft()
        draft.action = "答应了去接她"
        draft.setLoss("她白等了三个小时", for: .dignity)
        draft.ifRefused = "那就先不打扰"
        draft.stepIndex = RepairStep.losses.rawValue

        RepairDraftStore.save(draft, to: defaults)
        let loaded = RepairDraftStore.load(from: defaults)

        XCTAssertEqual(loaded?.action, "答应了去接她")
        XCTAssertEqual(loaded?.loss(.dignity), "她白等了三个小时")
        XCTAssertEqual(loaded?.stepIndex, RepairStep.losses.rawValue)
    }

    func testLoadWithoutSavedDraftReturnsNil() {
        XCTAssertNil(RepairDraftStore.load(from: defaults))
    }

    func testClearRemovesDraft() {
        var draft = RepairDraft()
        draft.action = "x"
        RepairDraftStore.save(draft, to: defaults)
        RepairDraftStore.clear(from: defaults)
        XCTAssertNil(RepairDraftStore.load(from: defaults))
    }
}

final class RepairTheoryCitationTests: XCTestCase {

    /// 每一步都必须能说清"凭什么"。
    ///
    /// 这条测试守的是可信度本身：如果某一步引入理论时没写清来源或没标注
    /// 证据强度，那个折叠区就会变成"看起来很有道理"的空话 ——
    /// 而空话比不引用更伤信任。
    func testEveryStepCarriesSourceAndCaveat() {
        for step in RepairStep.allCases {
            guard let theory = step.theory else {
                XCTFail("第 \(step.ordinal) 步「\(step.title)」缺少依据")
                continue
            }
            XCTAssertFalse(theory.source.isEmpty, "\(step.title) 缺少来源")
            XCTAssertFalse(theory.claim.isEmpty, "\(step.title) 缺少结论")
            XCTAssertFalse(
                theory.caveat.isEmpty,
                "\(step.title) 没有标注证据强度 —— 这会让人误以为它是实验定论"
            )
        }
    }

    func testCitationAvoidsAbsoluteClaims() {
        for step in RepairStep.allCases {
            guard let theory = step.theory else { continue }
            XCTAssertFalse(
                theory.claim.contains("科学证明"),
                "「\(step.title)」用了「科学证明」—— 这类表述一旦被追问就站不住，反而伤可信度"
            )
        }
    }
}
