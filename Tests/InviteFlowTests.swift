//
// InviteFlowTests.swift
// 关系CopilotTests
//
// 远程邀请的**整条链**：链接怎么拼、对方的内容怎么解、状态机怎么走。
//
// ## 为什么这些测试合在一个文件里
//
// 它们守的是同一个失败模式：**两端各自自洽，但接不上**。
// 交接屏显示"等 TA 写完"、对方网页显示"已提交"、服务端日志一切正常，
// 而人就在那儿永远等下去 —— 这类故障不抛异常、不报错、不留日志。
//
// 单项测试（链接拼得对 / JSON 解得开 / 状态机能迁移）全绿也没用，
// 所以这里刻意把它们串起来跑一遍完整往返，再分别钉住每个环节的边界。
//

import XCTest
import CryptoKit
import SwiftData
@testable import RelationshipCopilot

final class InviteFlowTests: XCTestCase {

    // MARK: - 链接构造

    func testInviteURLPutsKeyInFragmentNotQuery() throws {
        let link = InviteLink(caseId: "abcdefghijklmnop1234", keyBase64URL: "KEYKEYKEY")
        let url = try XCTUnwrap(link.url(proxyBaseURL: URL(string: "https://proxy.example.com")!))

        XCTAssertEqual(url.host, "proxy.example.com")
        XCTAssertEqual(url.path, "/v1/invite/abcdefghijklmnop1234/page")
        // 这一条是实现的地基：`#` 之后不会发到服务器。
        XCTAssertEqual(url.fragment, "KEYKEYKEY", "密钥必须在 fragment 里")
        XCTAssertNil(url.query, "密钥绝不能出现在 query 里")

        // 完整字符串层面的双重确认 —— 上面两条用的是 URLComponents 的语义，
        // 而真正被复制进聊天框的是 absoluteString。
        let text = url.absoluteString
        XCTAssertTrue(text.contains("#KEYKEYKEY"))
        XCTAssertFalse(text.contains("?k=") || text.contains("key="))
    }

    func testInviteURLKeepsBasePathPrefix() throws {
        // Worker 可能挂在子路径下（例如反向代理的 /api）。丢了前缀会打到根上。
        let link = InviteLink(caseId: "abcdefghijklmnop1234", keyBase64URL: "K")
        let url = try XCTUnwrap(link.url(proxyBaseURL: URL(string: "https://example.com/api")!))
        XCTAssertEqual(url.path, "/api/v1/invite/abcdefghijklmnop1234/page")
    }

    func testInviteURLRejectsBaseWithQueryOrFragment() {
        let link = InviteLink(caseId: "abcdefghijklmnop1234", keyBase64URL: "K")
        // 自带 fragment 会被我们的 #key 覆盖，自带 query 会把路径拼坏。
        // 两种都该明确失败，而不是拼出一个看起来能用、实际打不开的链接。
        XCTAssertNil(link.url(proxyBaseURL: URL(string: "https://example.com?a=1")!))
        XCTAssertNil(link.url(proxyBaseURL: URL(string: "https://example.com#x")!))
    }

    func testCaseIdFromGeneratorFitsServerPattern() {
        // 服务端 `CASE_ID_PATTERN` 要求 16–64 位 URL 安全字符。
        // 两边各有一套生成/校验，长度对不上会表现为"链接打不开"。
        for _ in 0 ..< 30 {
            let id = InviteSecret.makeCaseID()
            XCTAssertGreaterThanOrEqual(id.count, 16, "caseId 太短，服务端会拒绝：\(id)")
            XCTAssertLessThanOrEqual(id.count, 64, "caseId 太长，服务端会拒绝：\(id)")
            XCTAssertTrue(
                id.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" },
                "caseId 含服务端正则不接受的字符：\(id)"
            )
        }
    }

    // MARK: - 载荷解析

    /// 按网页端真实格式造一份密文。
    private func sealPayload(
        answers: [String: String],
        key: SymmetricKey
    ) throws -> InviteCiphertext {
        let payload: [String: Any] = [
            "slot": "b",
            "answers": answers,
            "submittedAt": 1_760_000_000_000 as Double, // 毫秒
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return try InviteCrypto.seal(text, key: key)
    }

    private var fullAnswers: [String: String] {
        [
            "happened": "周五晚上说好七点吃饭，我等到八点半。",
            "hurtMost": "不是等，是我发消息过去没有人回。",
            "request": "临时改时间的话，提前说一句。",
            "myPart": "我后来说话也很难听。",
        ]
    }

    func testPayloadRoundTripProducesCompleteTestimony() throws {
        let key = InviteSecret.makeKey()
        let sealed = try sealPayload(answers: fullAnswers, key: key)

        let payload = try InviteCrypto.openPayload(sealed, key: key)
        let testimony = try XCTUnwrap(payload.toTestimony(), "四题齐备时必须能转成证词")

        XCTAssertTrue(testimony.isComplete)
        XCTAssertEqual(testimony.happened, fullAnswers["happened"])
        XCTAssertEqual(testimony.hurtMost, fullAnswers["hurtMost"])
        XCTAssertEqual(testimony.request, fullAnswers["request"])
        XCTAssertEqual(testimony.myPart, fullAnswers["myPart"])
        // 网页给的是毫秒，必须正确换算 —— 按秒解释会落到 1970 年。
        XCTAssertEqual(testimony.submittedAt.timeIntervalSince1970, 1_760_000_000, accuracy: 1)
    }

    func testPayloadMissingAnyQuestionIsRejected() throws {
        let key = InviteSecret.makeKey()

        // 逐题缺失都要被拒。只测一题不够：`myPart` 是最容易漏的（也是心理支点），
        // 但 `hurtMost` 漏掉会让 needA/needB 的对称性校验拿不到情绪信息。
        for missing in TestimonyQuestion.allCases {
            var answers = fullAnswers
            answers[InvitePayload.webID(for: missing)] = nil

            let sealed = try sealPayload(answers: answers, key: key)
            let payload = try InviteCrypto.openPayload(sealed, key: key)

            XCTAssertNil(payload.toTestimony(), "缺「\(missing.title)」时不该被接受")
            XCTAssertEqual(
                payload.missingQuestions().map(\.title),
                [missing.title],
                "missingQuestions 应精确指出缺哪一题"
            )
        }
    }

    func testPayloadBlankAnswerCountsAsMissing() throws {
        let key = InviteSecret.makeKey()
        var answers = fullAnswers
        answers["request"] = "   \n  "

        let sealed = try sealPayload(answers: answers, key: key)
        let payload = try InviteCrypto.openPayload(sealed, key: key)

        // 全空白等于没写。若当它写了，模型会看到一条空白诉求 ——
        // 而那会被解读成"这一方什么也不要求"，是种隐性偏袒。
        XCTAssertNil(payload.toTestimony())
        XCTAssertEqual(payload.missingQuestions(), [.request])
    }

    func testPayloadRejectsWrongKey() throws {
        let sealed = try sealPayload(answers: fullAnswers, key: InviteSecret.makeKey())
        let otherKey = InviteSecret.makeKey()

        XCTAssertThrowsError(try InviteCrypto.openPayload(sealed, key: otherKey)) { error in
            XCTAssertEqual(error as? InvitePayloadError, .cannotOpen)
        }
    }

    func testPayloadRejectsNonJSONPlaintext() throws {
        let key = InviteSecret.makeKey()
        let sealed = try InviteCrypto.seal("这不是 JSON", key: key)

        // 拿到链接的人可以写任意内容上来。解不开或不是 JSON 都必须明确失败，
        // 而不能让解析器"尽力而为"地产出一份半空证词。
        XCTAssertThrowsError(try InviteCrypto.openPayload(sealed, key: key)) { error in
            guard case .malformed = (error as? InvitePayloadError) else {
                return XCTFail("期望 malformed，实际 \(error)")
            }
        }
    }

    func testWebIDMappingMatchesSwiftCases() {
        // 网页与 App 的字段名映射。写反了会表现为"对方写的第 3 题变成第 2 题"，
        // 内容读起来仍然通顺 —— 这是最难靠肉眼发现的一类错。
        XCTAssertEqual(InvitePayload.webID(for: .happened), "happened")
        XCTAssertEqual(InvitePayload.webID(for: .hurtMost), "hurtMost")
        XCTAssertEqual(InvitePayload.webID(for: .request), "request")
        XCTAssertEqual(InvitePayload.webID(for: .myPart), "myPart")

        // 每个 case 都要有映射，且互不相同。
        let ids = TestimonyQuestion.allCases.map(InvitePayload.webID(for:))
        XCTAssertEqual(Set(ids).count, TestimonyQuestion.allCases.count, "映射有重复：\(ids)")
    }

    // MARK: - 状态机

    func testRemoteAllowsTwoPartyTransitions() {
        // 这三条是远程模式的骨架。用 `== .sameDevice` 判断时它们全都会返回 false，
        // 而编译器不会报错（`.solo` 分支兜着），表现为"提交后没反应"。
        XCTAssertTrue(
            DisputeCaseState.collectingA.canTransition(to: .waitingForB, mode: .remote),
            "远程模式 A 提交后必须能进入等对方"
        )
        XCTAssertTrue(
            DisputeCaseState.waitingForB.canTransition(to: .collectingB, mode: .remote),
            "远程模式收到对方证词时必须能进入 B 已写"
        )
        XCTAssertTrue(
            DisputeCaseState.collectingB.canTransition(to: .ready, mode: .remote),
            "远程模式 B 写完必须能进入可生成"
        )

        // 但远程不能"退回上一个作者重写" —— A 的设备上并没有正在写的 B。
        XCTAssertFalse(DisputeCaseState.collectingB.canTransition(to: .collectingA, mode: .remote))
        XCTAssertTrue(DisputeCaseState.collectingB.canTransition(to: .collectingA, mode: .sameDevice))
    }

    func testIsTwoPartySemantics() {
        XCTAssertTrue(DisputeMode.sameDevice.isTwoParty)
        XCTAssertTrue(DisputeMode.remote.isTwoParty)
        XCTAssertFalse(DisputeMode.solo.isTwoParty)

        XCTAssertTrue(DisputeMode.remote.requiresCounterpartDevice)
        XCTAssertFalse(DisputeMode.sameDevice.requiresCounterpartDevice)
        XCTAssertFalse(DisputeMode.solo.requiresCounterpartDevice)

        XCTAssertTrue(DisputeMode.sameDevice.isHandoverByDevice)
        XCTAssertFalse(DisputeMode.remote.isHandoverByDevice)
    }

    // MARK: - 闸门

    func testGateRequiresSideBInRemoteMode() {
        // 这一条守的是一处静默失效：`if mode == .sameDevice` 会让远程模式
        // 跳过 B 的全部检查，于是拿半份证词去评理，而结果看起来完全正常。
        let onlyA = DisputeTestimony(
            happened: "a", hurtMost: "b", request: "c", myPart: "d"
        )

        let rejection = DisputeCaseGate.check(
            state: .ready, mode: .remote, sideA: onlyA, sideB: nil
        )
        XCTAssertEqual(rejection, .missingTestimony(.b), "远程模式缺 B 必须被拦住")

        // 同机模式当然也要拦。
        XCTAssertEqual(
            DisputeCaseGate.check(state: .ready, mode: .sameDevice, sideA: onlyA, sideB: nil),
            .missingTestimony(.b)
        )

        // 单机模式不要求 B —— 这是它存在的意义。
        XCTAssertNil(DisputeCaseGate.check(state: .ready, mode: .solo, sideA: onlyA, sideB: nil))
    }

    func testGateRejectsIncompleteSideBInRemoteMode() {
        let complete = DisputeTestimony(happened: "a", hurtMost: "b", request: "c", myPart: "d")
        // 少一题的 B：通过闸门就等于把"漏填"当成"没话说"喂给模型。
        let halfB = DisputeTestimony(happened: "a", hurtMost: "b", request: "c", myPart: "")

        XCTAssertEqual(
            DisputeCaseGate.check(state: .ready, mode: .remote, sideA: complete, sideB: halfB),
            .incompleteTestimony(.b)
        )
    }

    func testRequestKeepsSideBInRemoteMode() {
        // `DisputeRequest.init` 早先用 `mode == .sameDevice` 三元判断，
        // 远程模式下会把对方那份**直接丢掉**。这里从构造器层面钉住它。
        let a = DisputeTestimony(happened: "a", hurtMost: "b", request: "c", myPart: "d")
        let b = DisputeTestimony(happened: "w", hurtMost: "x", request: "y", myPart: "z")

        let remote = DisputeRequest(mode: .remote, relationshipLabel: "伴侣", sideA: a, sideB: b)
        XCTAssertNotNil(remote.sideB, "远程模式必须保留 B 的证词")

        let same = DisputeRequest(mode: .sameDevice, relationshipLabel: "伴侣", sideA: a, sideB: b)
        XCTAssertNotNil(same.sideB)

        // 单机模式必须抹掉 B，否则就是"假装中立"。
        let solo = DisputeRequest(mode: .solo, relationshipLabel: "伴侣", sideA: a, sideB: b)
        XCTAssertNil(solo.sideB, "单机模式绝不能带 B 进提示词")
    }
}
