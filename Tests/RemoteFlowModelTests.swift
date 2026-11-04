//
// RemoteFlowModelTests.swift
// 关系CopilotTests
//
// 远程模式在 `DisputeFlowModel` 上的行为。
//
// ## 用假服务而不是真网络
//
// 邀请链路的每一环都可能被网络延迟、KV 最终一致性、服务端部署状态干扰，
// 所以这里全部注入假实现。要验证的是**我们自己的决策**：
//   · 拿到对方那份之后，状态机是否真的走到了 ready
//   · 内容不完整/解不开时，是否明确报错而不是静默停在等待态
//   · 密钥是否在用过之后被清掉
//
// 「对方还没写」这个分支尤其重要：它必须与「对方写了但 KV 还没同步」区分开，
// 否则用户会以为对方放鸽子。
//

import XCTest
import SwiftData
import CryptoKit
@testable import RelationshipCopilot

@MainActor
final class RemoteFlowModelTests: XCTestCase {

    // MARK: - 假服务

    private final class StubInviteService: InviteServicing {
        var status: InviteStatus
        var error: Error?
        private(set) var callCount = 0

        init(status: InviteStatus) {
            self.status = status
        }

        func fetchStatus(caseId: String) async throws -> InviteStatus {
            callCount += 1
            if let error { throw error }
            return status
        }
    }

    private static let emptyStatus = InviteStatus(
        slots: .init(a: false, b: false),
        awaiting: ["b"],
        testimonies: [:]
    )

    // MARK: - 环境

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        // 复用 `DataEraser.modelTypes` 而不是在这里另列一份模型清单 ——
        // 另列一份的后果是：将来新增模型时这里不会报错，
        // 但插入新模型的测试会在运行期才失败（而且信息很难懂）。
        let schema = Schema(DataEraser.modelTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
    }

    /// 造一件处于「A 写完、等对方」状态的远程案卷。
    private func makeWaitingCase() throws -> DisputeCase {
        let disputeCase = DisputeCase(title: "一次没说清的事", mode: .remote)
        context.insert(disputeCase)
        let testimony = DisputeTestimony(
            happened: "周五晚上说好七点吃饭，我等到八点半。",
            hurtMost: "我发消息过去没有人回。",
            request: "临时改时间的话提前说一句。",
            myPart: "我后来说话也很难听。"
        )
        let next = disputeCase.submit(testimony, by: .a)
        XCTAssertEqual(next, .waitingForB, "远程模式 A 提交后应停在等对方")
        try context.save()
        return disputeCase
    }

    private func sealedForModel(
        answers: [String: String],
        key: SymmetricKey
    ) throws -> InviteCiphertext {
        let payload: [String: Any] = ["slot": "b", "answers": answers, "submittedAt": Date().timeIntervalSince1970 * 1000]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try InviteCrypto.seal(try XCTUnwrap(String(data: data, encoding: .utf8)), key: key)
    }

    private let counterpartAnswers = [
        "happened": "那天临时被叫去开会，手机没在身边。",
        "hurtMost": "回来看到你说的话，我也很难受。",
        "request": "有事没回的话，希望不要直接下结论。",
        "myPart": "我应该先发一句我要开会。",
    ]

    // MARK: - 邀请材料的生命周期

    func testEnsureInviteLinkIsIdempotent() throws {
        let disputeCase = try makeWaitingCase()
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))

        let first = try XCTUnwrap(model.ensureInviteLink(for: disputeCase, context: context))
        let second = try XCTUnwrap(model.ensureInviteLink(for: disputeCase, context: context))

        // 换密钥等于让对方手里那条链接作废。用户切个后台再回来就会触发，
        // 所以这里必须是复用而不是重新生成。
        XCTAssertEqual(first.caseId, second.caseId)
        XCTAssertEqual(first.keyBase64URL, second.keyBase64URL)
        XCTAssertEqual(disputeCase.inviteLink, first)
    }

    func testConsumeInviteKeyClearsSecretButKeepsCaseId() throws {
        let disputeCase = try makeWaitingCase()
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))
        let link = try XCTUnwrap(model.ensureInviteLink(for: disputeCase, context: context))

        disputeCase.consumeInviteKey()

        // 密钥用完即弃：已经解开的内容没有理由让密钥继续躺在库里。
        XCTAssertNil(disputeCase.inviteKeyBase64URL)
        XCTAssertTrue(disputeCase.inviteKeyConsumed)
        // caseId 保留 —— 它不含秘密，界面还要靠它刷新状态。
        XCTAssertEqual(disputeCase.inviteCaseId, link.caseId)
        XCTAssertNil(disputeCase.inviteLink, "缺密钥时不该还能构造出链接")
    }

    // MARK: - 对方还没写

    func testRefreshWithoutCounterpartKeepsWaiting() async throws {
        let disputeCase = try makeWaitingCase()
        let stub = StubInviteService(status: Self.emptyStatus)
        let model = DisputeFlowModel(case: disputeCase, inviteService: stub)
        _ = model.ensureInviteLink(for: disputeCase, context: context)

        let done = await model.refreshInvite(for: disputeCase, context: context)

        XCTAssertFalse(done)
        XCTAssertEqual(disputeCase.state, .waitingForB, "对方没写时状态不能变")
        XCTAssertNil(model.inviteErrorMessage, "查不到不是错误，不该报错")
        XCTAssertEqual(stub.callCount, 1)
    }

    // MARK: - 对方写完了

    func testRefreshDecryptsAndAdvancesToReady() async throws {
        let disputeCase = try makeWaitingCase()
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))
        let link = try XCTUnwrap(model.ensureInviteLink(for: disputeCase, context: context))
        let key = try InviteCrypto.key(fromBase64URL: link.keyBase64URL)

        let sealed = try sealedForModel(answers: counterpartAnswers, key: key)
        let stub = StubInviteService(status: InviteStatus(
            slots: .init(a: false, b: true),
            awaiting: [],
            testimonies: ["b": sealed]
        ))
        let remote = DisputeFlowModel(case: disputeCase, inviteService: stub)

        let done = await remote.refreshInvite(for: disputeCase, context: context)

        XCTAssertTrue(done, "四题齐备时必须成功取回")
        XCTAssertEqual(disputeCase.state, .ready, "取回后必须走到可生成")
        XCTAssertEqual(remote.state, .ready, "模型的 state 也要同步，否则界面不动")
        XCTAssertEqual(disputeCase.sideB?.happened, counterpartAnswers["happened"])
        XCTAssertEqual(disputeCase.sideB?.myPart, counterpartAnswers["myPart"])
        // 密钥用过即清。
        XCTAssertTrue(disputeCase.inviteKeyConsumed)
        XCTAssertNil(disputeCase.inviteKeyBase64URL)
    }

    func testRefreshReportsIncompleteCounterpartClearly() async throws {
        let disputeCase = try makeWaitingCase()
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))
        let link = try XCTUnwrap(model.ensureInviteLink(for: disputeCase, context: context))
        let key = try InviteCrypto.key(fromBase64URL: link.keyBase64URL)

        // 只写三题 —— 老版本网页就会产出这种内容。
        var partial = counterpartAnswers
        partial["myPart"] = nil
        let sealed = try sealedForModel(answers: partial, key: key)

        let remote = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: InviteStatus(
            slots: .init(a: false, b: true),
            awaiting: [],
            testimonies: ["b": sealed]
        )))

        let done = await remote.refreshInvite(for: disputeCase, context: context)

        XCTAssertFalse(done)
        XCTAssertEqual(disputeCase.state, .waitingForB, "内容不全时不能推进状态")
        // 错误必须说清缺什么，而不是一句"格式不对"——用户要据此让对方补写。
        let message = try XCTUnwrap(remote.inviteErrorMessage)
        XCTAssertTrue(message.contains("缺"), "错误信息应指出缺题：\(message)")
        XCTAssertTrue(message.contains("你自己那一份"), "应指出具体缺哪一题：\(message)")
    }

    func testRefreshReportsWrongKeyAsCannotOpen() async throws {
        let disputeCase = try makeWaitingCase()
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))
        _ = model.ensureInviteLink(for: disputeCase, context: context)

        // 用另一把钥匙加密 —— 模拟链接被改过、或内容被动过。
        let sealed = try sealedForModel(answers: counterpartAnswers, key: InviteSecret.makeKey())
        let remote = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: InviteStatus(
            slots: .init(a: false, b: true),
            awaiting: [],
            testimonies: ["b": sealed]
        )))

        let done = await remote.refreshInvite(for: disputeCase, context: context)

        XCTAssertFalse(done)
        XCTAssertEqual(disputeCase.state, .waitingForB)
        XCTAssertNotNil(remote.inviteErrorMessage)
        // 不能把内容写进去 —— 写进去就是"用错误密钥解出了乱码并当成证词"。
        XCTAssertNil(disputeCase.sideB)
    }

    // MARK: - 退回同机模式

    func testSwitchToSameDeviceKeepsSideAAndReturnsToCollecting() throws {
        let disputeCase = try makeWaitingCase()
        let originalA = try XCTUnwrap(disputeCase.sideA)
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))
        _ = model.ensureInviteLink(for: disputeCase, context: context)

        model.switchToSameDevice(disputeCase, context: context)

        XCTAssertEqual(disputeCase.mode, .sameDevice)
        XCTAssertEqual(disputeCase.state, .collectingA)
        XCTAssertEqual(model.state, .collectingA)
        // A 已经写过的那份是劳动成果，退回不能让他重写。
        XCTAssertEqual(disputeCase.sideA, originalA)
        XCTAssertEqual(model.draft, originalA, "草稿要填回已写内容，而不是空表单")
        // 邀请材料作废。
        XCTAssertNil(disputeCase.inviteCaseId)
        XCTAssertNil(disputeCase.inviteKeyBase64URL)
    }

    func testSwitchToSameDeviceIsIgnoredForNonRemoteCases() throws {
        let disputeCase = DisputeCase(title: "t", mode: .sameDevice)
        context.insert(disputeCase)
        let model = DisputeFlowModel(case: disputeCase, inviteService: StubInviteService(status: Self.emptyStatus))

        model.switchToSameDevice(disputeCase, context: context)

        // 非远程模式下这个动作完全没有意义，不该把状态打乱。
        XCTAssertEqual(disputeCase.mode, .sameDevice)
        XCTAssertEqual(disputeCase.state, .collectingA)
    }
}
