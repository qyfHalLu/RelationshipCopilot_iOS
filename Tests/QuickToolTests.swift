//
//  QuickToolTests.swift
//  RelationshipCopilotTests
//
//  快速工具的设计约束。
//
//  ## 这里测的不是功能，是**产品立场**
//
//  用户提过一个很准的问题：如果被道歉的人知道这段话是 AI 生成的，
//  只会更生气 —— 因为"你连道歉都要别人代笔"。
//
//  这不是误用，是设计错位：道歉的价值不在文字得体，
//  而在"我有没有真的理解我伤到你哪里"，AI 代写恰好跳过了理解。
//
//  所以「替你说话」类工具必须降级为「陪你想」。
//  但这些约束写在提示词里，**模型随时可能被换成另一个、或者有人顺手"优化"回去**。
//  所以要由测试守住：产出必须是要点，不是成品。
//

import XCTest
@testable import RelationshipCopilot

final class QuickToolTests: XCTestCase {

    // MARK: 工具清单

    /// 关系体检已删除。
    ///
    /// 它的问题不是做得不好，是方向错：名字叫"体检"、输出是"薄弱环节"，
    /// 本质仍在给关系打分做评估 —— 而这个产品是从「85 分」里走出来的。
    func testCheckupIsRemoved() {
        XCTAssertEqual(
            Set(QuickToolKind.allCases.map(\.rawValue)),
            ["conflict", "phrase", "apology"],
            "工具清单变了：关系体检应当已删除"
        )
    }

    /// 只有「替用户说话」的工具需要用户改成自己的话。
    /// 吵架复盘不产出要说的话，只是帮人看清，所以不需要。
    func testOnlySpeakingToolsRequireOwnWords() {
        XCTAssertFalse(QuickToolKind.conflict.requiresOwnWords)
        XCTAssertTrue(QuickToolKind.phrase.requiresOwnWords)
        XCTAssertTrue(QuickToolKind.apology.requiresOwnWords)
    }

    // MARK: 提示词立场

    /// 道歉工具**不得**要求模型写一段完整可用的道歉。
    ///
    /// 旧的提示词是"写一段 120 字以内的道歉" —— 那正是代笔。
    func testApologyPromptDoesNotAskForFinishedText() {
        let prompt = QuickToolKind.apology.systemPrompt
        XCTAssertFalse(
            prompt.contains("写一段 120 字以内的道歉"),
            "道歉提示词退回了「代笔」模式：要求模型直接写成品"
        )
        XCTAssertTrue(
            prompt.contains("不要写一段可以复制粘贴的道歉"),
            "道歉提示词缺少「不给成品」的明确约束"
        )
    }

    /// 道歉必须追问"对方失去了什么"，而不是只写"让对方不开心"。
    /// 这一段是最容易被跳过、也最能决定道歉是否真诚的部分。
    func testApologyPromptAsksForConcreteLoss() {
        let prompt = QuickToolKind.apology.systemPrompt
        XCTAssertTrue(prompt.contains("对方因此失去了什么"))
        XCTAssertTrue(prompt.contains("具体的损失"))
    }

    /// 开口工具同样不许给可复制的话术。
    func testPhrasePromptDoesNotProduceCopyPasteScript() {
        let prompt = QuickToolKind.phrase.systemPrompt
        XCTAssertFalse(
            prompt.contains("3 句可以直接发送的话"),
            "开口准备退回了「给话术」模式"
        )
        XCTAssertTrue(prompt.contains("不要给他一段可以复制粘贴的话"))
    }

    /// 提示词不得自相矛盾：不能一边要求"给现成的原话"，一边要求"不要给成品"。
    ///
    /// ## 这一条是补上的漏网之鱼
    ///
    /// common 的第三条原本是「给出可以直接使用的原话」，对三个工具都生效，
    /// 而 `phrase` / `apology` 的正文写的是「不要给他一段可以复制粘贴的话」。
    /// 两条同时出现在同一个 system prompt 里，模型只能摇摆。
    ///
    /// 之前的测试只断言了"有禁止给成品的句子"，**没有断言"没有要求给成品的句子"**，
    /// 所以矛盾一直存在而测试全绿 —— 断言只覆盖了它度量的那一面。
    func testPhraseAndApologyPromptsAreNotSelfContradictory() {
        for tool in [QuickToolKind.phrase, .apology] {
            let prompt = tool.systemPrompt
            XCTAssertFalse(
                prompt.contains("可以直接使用的原话"),
                "\(tool.rawValue) 的提示词同时要求「给原话」和「不要给成品」，模型会摇摆"
            )
        }
    }

    /// 吵架复盘**确实需要**原话（它给的是"今晚可以说的一句"）。
    /// 上一条的修正不能误伤它。
    func testConflictPromptKeepsAskingForActualWords() {
        XCTAssertTrue(
            QuickToolKind.conflict.systemPrompt.contains("可以直接使用的原话"),
            "吵架复盘需要一句能说出口的话，不该被「禁止给原话」的修正波及"
        )
    }

    /// 开口工具的示范必须是"粗糙"的。
    ///
    /// 示范越像文案，用户越倾向于照念；越粗糙，用户越会改成自己的说法。
    /// 这是用产出物的质感来防止"表演"。
    func testPhrasePromptAsksForRoughDemo() {
        let prompt = QuickToolKind.phrase.systemPrompt
        XCTAssertTrue(prompt.contains("粗糙"))
        XCTAssertTrue(prompt.contains("改成你自己的说法"))
    }

    /// 吵架复盘不产出要发送的话，所以它的提示词里**不该**出现"你可以说这一句"之外的成品要求。
    /// 它给的是"今晚可以说的一句"，但那是在帮用户找到自己的话，不是代替他写。
    func testConflictPromptStaysOnClarifyingNotGhostwriting() {
        let prompt = QuickToolKind.conflict.systemPrompt
        XCTAssertTrue(prompt.contains("不得判断谁对谁错"))
        XCTAssertTrue(prompt.contains("不得分配责任"))
        // 它应该把双人场景引导到评理，而不是自己承担"评理"的职责
        XCTAssertTrue(prompt.contains("评理"))
    }

    /// 所有工具都不得产出"关系分数"。
    /// 这是删除「关系健康度」之后立下的红线。
    func testNoToolAsksForScores() {
        for tool in QuickToolKind.allCases {
            let prompt = tool.systemPrompt
            XCTAssertFalse(
                prompt.contains("评分") || prompt.contains("打分") || prompt.contains("分数"),
                "\(tool.rawValue) 的提示词里出现了打分要求"
            )
        }
    }

    // MARK: 离线兜底

    /// AI 不可用时给的静态内容必须**自称通用参考**，不能伪装成个性化结果。
    func testOfflineReferenceIsLabelled() {
        for tool in QuickToolKind.allCases {
            XCTAssertTrue(
                tool.offlineReference.contains("通用参考"),
                "\(tool.rawValue) 的离线内容没有标明是通用参考"
            )
        }
    }

    // MARK: 语音输入

    /// 语音识别的拼接逻辑：已有内容 + 新说的话，中间要补标点。
    ///
    /// 不补的话会变成「他昨天回来很晚我有点难过」这种读不通的长句。
    func testVoiceMergeInsertsSeparator() {
        XCTAssertEqual(
            VoiceInputButton.merge(base: "他昨天回来很晚", spoken: "我有点难过"),
            "他昨天回来很晚。我有点难过"
        )
    }

    /// 已有内容以标点结尾时，不重复补标点。
    func testVoiceMergeDoesNotDuplicatePunctuation() {
        XCTAssertEqual(
            VoiceInputButton.merge(base: "他昨天回来很晚。", spoken: "我有点难过"),
            "他昨天回来很晚。我有点难过"
        )
    }

    /// 空白起点：直接写入，不补前导标点。
    func testVoiceMergeFromEmpty() {
        XCTAssertEqual(VoiceInputButton.merge(base: "", spoken: "我有点难过"), "我有点难过")
        XCTAssertEqual(VoiceInputButton.merge(base: "   ", spoken: "我有点难过"), "我有点难过")
    }

    /// 识别结果为空时保持原有内容不变（说话前停顿、识别没出字）。
    func testVoiceMergeKeepsBaseWhenNothingSpoken() {
        XCTAssertEqual(VoiceInputButton.merge(base: "已经写好的", spoken: ""), "已经写好的")
    }

    // MARK: 语音覆盖与文案一致性

    /// 列表页对每个工具的承诺，必须和它内部的提示词立场一致。
    ///
    /// ## 这条测试的由来
    ///
    /// 「开口准备」的列表说明原写「给你几句现在就能发出去的话」，
    /// 而它的提示词第一条就是「不要给他一段可以复制粘贴的话」。
    /// 用户在列表页看到的是"能拿到能发的句子"，点进去却只拿到三个要点 ——
    /// 从他的角度看，是功能坏了；从产品角度看，是**列表在说谎**。
    ///
    /// 这类"文案与实现脱节"每次都是靠人读代码发现的，所以钉在这里。
    func testListDescriptionMatchesNoGhostwritingStance() {
        for tool in QuickToolKind.allCases where tool.requiresOwnWords {
            let detail = tool.detail
            XCTAssertFalse(
                detail.contains("发出去的话") || detail.contains("现成的话术"),
                "\(tool.rawValue) 的列表说明承诺了可直接发送的话，但它要求用户用自己的话"
            )
        }
    }

    /// 文案里不写死流程步数。
    ///
    /// 「道歉准备」曾写「六步想清楚」，而实现是七步。
    /// 步数会随设计调整而变，写死的数字没有机制保证同步 —— 不如不写。
    func testDescriptionDoesNotHardcodeStepCount() {
        for tool in QuickToolKind.allCases {
            let detail = tool.detail
            for numeral in ["两步", "三步", "四步", "五步", "六步", "七步", "八步"] {
                XCTAssertFalse(
                    detail.contains(numeral),
                    "\(tool.rawValue) 的列表说明写死了「\(numeral)」，流程一改就会过期"
                )
            }
        }
    }

    // MARK: 麦克风互斥

    /// 同一屏只允许一个按钮占着麦克风。
    ///
    /// 道歉准备第 3 步有七个格子，每格一个麦克风。若两个同时录，
    /// iOS 不会报错 —— 两路 buffer 各喂各的识别请求，
    /// 于是两个输入框同时进字，用户根本无法判断字进了哪里。
    @MainActor
    func testVoiceCoordinatorAllowsOnlyOneOwner() {
        let coordinator = VoiceInputCoordinator()
        let first = UUID()
        let second = UUID()

        coordinator.claim(first)
        XCTAssertEqual(coordinator.active, first)

        // 第二个占坑后，第一个应当知道自己被抢了
        coordinator.claim(second)
        XCTAssertTrue(coordinator.isPreempted(first), "被抢占的按钮没有收到通知，会继续录")
        XCTAssertFalse(coordinator.isPreempted(second))

        // 抢占者在录，被抢占者不该同时认为自己在录
        coordinator.release(first)
        XCTAssertEqual(coordinator.active, second, "被抢占者退出时把抢占者的坑清掉了")
    }

    /// 晚到的释放不能清掉别人的坑。
    ///
    /// 时序：A 开始录 → B 抢占 → A 的 `onChange` 回调此刻才跑到 release。
    /// 如果 release 不看身份就清空，B 会在正录着的时候失去占位，
    /// 之后 C 再来抢占就不会被拦。
    @MainActor
    func testStaleReleaseDoesNotClearNewOwner() {
        let coordinator = VoiceInputCoordinator()
        let a = UUID()
        let b = UUID()

        coordinator.claim(a)
        coordinator.claim(b)
        coordinator.release(a)

        XCTAssertEqual(coordinator.active, b, "旧持有者的迟到释放清掉了新持有者")
    }

    /// 没人在录时，任何按钮都不算被抢占（否则第一次点击就会被自己拦掉）。
    @MainActor
    func testNoOwnerMeansNoPreemption() {
        let coordinator = VoiceInputCoordinator()
        XCTAssertFalse(coordinator.isPreempted(UUID()))
    }
}

// MARK: - 失败时的产出决策

/// `AssistFallback` 的断言。
///
/// 这一组测试守的是一件很具体的事：**不要让故障伪装成正常结果**。
///
/// 旧实现在兜底 `catch` 里无条件把 `output` 设成 `offlineReference`，
/// 于是 401 / 超时 / 500 / 输出截断全都显示成「通用参考（未个性化）」。
/// 用户会以为 AI 给了他建议。内测阶段这等于把反馈渠道关掉。
final class AssistFallbackTests: XCTestCase {

    /// 网络类故障必须报错，**不能**降级成通用参考。
    ///
    /// 逐条列出，因为漏一种就是漏一种：
    /// 401（令牌没配好）、超时、服务端 5xx、AI 输出无法解析。
    func testTransientAndAuthFailuresDoNotFakeContent() {
        let failures: [AppError] = [
            .unauthorized,
            .timedOut,
            .offline,
            .serverError(500),
            .malformedAIResponse("截断"),
            .transcriptionFailed("转录为空"),
        ]

        for error in failures {
            let outcome = AssistFallback.outcome(for: error, tool: .conflict)
            XCTAssertEqual(
                outcome,
                .failed(error),
                "\(error) 被降级成了内容。用户会看到「通用参考」并以为 AI 正常工作。"
            )
            XCTAssertNil(outcome.text, "\(error) 不该产出任何文本")
            XCTAssertFalse(outcome.isAIGenerated, "\(error) 不该被标成 AI 生成")
        }
    }

    /// 只有"这台设备眼下确实没有 AI 可用"才降级，且必须标成非 AI 产出。
    func testOnlyUnavailableReasonsFallBackToReference() {
        for error in [AppError.aiNotConfigured, .quotaExceeded] {
            let outcome = AssistFallback.outcome(for: error, tool: .apology)
            XCTAssertEqual(outcome, .reference(QuickToolKind.apology.offlineReference))
            XCTAssertEqual(outcome.text, QuickToolKind.apology.offlineReference)
            XCTAssertFalse(
                outcome.isAIGenerated,
                "离线参考被标成了 AI 生成 —— 界面上会显示「AI 生成」，这是撒谎"
            )
        }
    }

    /// 离线参考必须自带「通用参考」字样。
    ///
    /// 即使 `isAIGenerated` 判断错了，正文也还留着一层诚实标记。
    /// 两道独立的防线，因为这一条一旦破，用户就完全无从分辨。
    func testReferenceTextLabelsItself() {
        for tool in QuickToolKind.allCases {
            let outcome = AssistFallback.outcome(for: .quotaExceeded, tool: tool)
            XCTAssertTrue(
                (outcome.text ?? "").contains("通用参考"),
                "\(tool.rawValue) 的离线参考没有自我标注"
            )
        }
    }

    /// `generated` 才算是 AI 产出。
    func testGeneratedIsMarkedAsAI() {
        let outcome = AssistFallback.Outcome.generated("今晚可以说：我需要十分钟")
        XCTAssertTrue(outcome.isAIGenerated)
        XCTAssertEqual(outcome.text, "今晚可以说：我需要十分钟")
    }
}
