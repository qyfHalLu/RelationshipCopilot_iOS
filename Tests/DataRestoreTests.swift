//
//  DataRestoreTests.swift
//  关系CopilotTests
//
//  「导出 → 清空 → 恢复」这条链路。
//
//  ## 为什么这组测试值得写这么细
//
//  导入是**唯一会大面积写库**的操作，而且它救的正是"已经丢过一次数据"的用户。
//  这里出错的后果不是难看，是把他仅存的那份备份也写坏。
//
//  所以每个用例都在验一件具体的事，而不是"能跑通"：
//    · 往返之后，**字段有没有真的回来**（不是条数对就算成功）
//    · 重复导入是否幂等（用户很可能连点两次）
//    · 覆盖模式是否真的清掉了本机独有的数据
//    · 坏文件/未来版本是否被明确拒绝，而不是"导入 0 条说成功"
//

import XCTest
import SwiftData
@testable import RelationshipCopilot

@MainActor
final class DataRestoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try makeContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(DataEraser.modelTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 造数据

    @discardableResult
    private func seedSampleData() throws -> (profileID: UUID, promiseID: UUID, sessionID: UUID, disputeID: UUID) {
        let profile = Profile(name: "小林", relationshipType: RelationshipType.partner.rawValue)
        profile.note = "怕吵，晚上不爱说话"
        profile.setIntimacy(8)
        profile.avatar = AvatarStorage.encode(colorHex: "6366F1")
        context.insert(profile)

        let promise = Promise(content: "这周三把饭补上", promisor: "user", promisee: "小林")
        promise.profile = profile
        promise.trackingStatus = PromiseStatus.active.rawValue
        promise.deadline = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(promise)

        let record = FulfillmentRecord(
            recordDate: Calendar.current.startOfDay(for: Date()),
            status: FulfillmentStatus.fulfilled.rawValue
        )
        record.promise = promise
        context.insert(record)
        promise.recalculateStats()

        let session = RecordingSession(sessionType: SessionKind.conflict.rawValue)
        session.profile = profile
        session.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        session.transcription = "她说最近总是我先睡着。"
        session.status = SessionStatus.analyzed.rawValue
        session.analysisResult = AnalysisResult(emotionScore: 72, summary: "都在讲道理。")
        context.insert(session)

        let dispute = DisputeCase(title: "她说我总在解释", mode: .sameDevice)
        dispute.profile = profile
        dispute.sideA = DisputeTestimony(
            happened: "她说完我就开始给方案。",
            hurtMost: "她说「跟你说也没用」。",
            request: "希望她直接说现在不想听建议。",
            myPart: "我听得太急了。",
            submittedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        dispute.sideB = DisputeTestimony(
            happened: "我还没说完他就开始分析。",
            hurtMost: "他一次都没问过我什么感觉。",
            request: "先陪我待一会儿。",
            myPart: "我也没说清楚。",
            submittedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        dispute.verdict = DisputeVerdict(
            reframe: "你们在争两件事。",
            needA: "想被承认是好意的。",
            needB: "想被承认的是感受。",
            stuckPoint: "卡在谁先让步。",
            solvability: .solvable,
            action: "先说一句「那一定很难受」。",
            coexistence: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        dispute.state = .closed
        dispute.closedAt = Date(timeIntervalSince1970: 1_700_000_400)
        context.insert(dispute)

        try context.save()
        return (profile.id, promise.id, session.id, dispute.id)
    }

    // MARK: - 往返

    /// 导出 → 全新空库 → 恢复：条数与**每个关键字段**都要回来。
    ///
    /// 只断言条数是不够的：条数对而字段错，用户看到的是一堆空记录，
    /// 而"恢复成功"的提示照样会显示。
    func testRoundTripPreservesFields() throws {
        let ids = try seedSampleData()

        let data = try DataExporter.build(context: context)
        let backup = try DataRestorer.parse(data)
        XCTAssertEqual(backup.profiles.count, 1)
        XCTAssertEqual(backup.promises.count, 1)
        XCTAssertEqual(backup.sessions.count, 1)
        XCTAssertEqual(backup.disputes.count, 1)

        // 换一个干净库，模拟换手机
        let freshContainer = try makeContainer()
        let freshContext = ModelContext(freshContainer)

        let preview = DataRestorer.preview(backup, in: freshContext)
        XCTAssertEqual(preview.newProfiles, 1)
        XCTAssertEqual(preview.newDisputes, 1)
        XCTAssertEqual(preview.duplicateItems, 0)

        let report = try DataRestorer.restore(backup, into: freshContext, policy: .merge)
        XCTAssertEqual(report.insertedProfiles, 1)
        XCTAssertEqual(report.insertedPromises, 1)
        XCTAssertEqual(report.insertedRecords, 1)
        XCTAssertEqual(report.insertedSessions, 1)
        XCTAssertEqual(report.insertedDisputes, 1)
        XCTAssertEqual(report.skippedExisting, 0)

        // 人物
        let profiles = try freshContext.fetch(FetchDescriptor<Profile>())
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.id, ids.profileID, "id 没保住，承诺/案卷就挂不回去")
        XCTAssertEqual(profile.name, "小林")
        XCTAssertEqual(profile.note, "怕吵，晚上不爱说话")
        XCTAssertEqual(profile.intimacyScore, 8, "亲密度没有恢复")
        XCTAssertEqual(profile.avatar, AvatarStorage.encode(colorHex: "6366F1"))

        // 承诺：内容、双方、截止时间、打卡记录、关联档案
        let promises = try freshContext.fetch(FetchDescriptor<Promise>())
        let promise = try XCTUnwrap(promises.first)
        XCTAssertEqual(promise.id, ids.promiseID)
        XCTAssertEqual(promise.content, "这周三把饭补上")
        XCTAssertEqual(promise.promisor, "user")
        XCTAssertEqual(promise.promisee, "小林")
        XCTAssertEqual(promise.deadline, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(promise.fulfillmentRecords?.count, 1, "打卡记录丢了")
        XCTAssertEqual(promise.profile?.id, ids.profileID, "承诺没挂回人物档案")

        // 对话记录
        let sessions = try freshContext.fetch(FetchDescriptor<RecordingSession>())
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, ids.sessionID)
        XCTAssertEqual(session.transcription, "她说最近总是我先睡着。")
        XCTAssertEqual(session.analysisResult?.summary, "都在讲道理。")
        XCTAssertEqual(session.profile?.id, ids.profileID)

        // 评理：证词原文与判词
        let disputes = try freshContext.fetch(FetchDescriptor<DisputeCase>())
        let dispute = try XCTUnwrap(disputes.first)
        XCTAssertEqual(dispute.id, ids.disputeID)
        XCTAssertEqual(dispute.state, .closed)
        XCTAssertEqual(dispute.sideA?.hurtMost, "她说「跟你说也没用」。")
        XCTAssertEqual(dispute.sideB?.request, "先陪我待一会儿。")
        XCTAssertEqual(dispute.verdict?.action, "先说一句「那一定很难受」。")
        XCTAssertEqual(dispute.verdict?.solvability, .solvable)
        XCTAssertEqual(dispute.profile?.id, ids.profileID)
    }

    /// 重复导入必须幂等：第二次应当全部跳过、一条都不新增。
    func testMergeIsIdempotent() throws {
        try seedSampleData()
        let backup = try DataRestorer.parse(try DataExporter.build(context: context))

        let first = try DataRestorer.restore(backup, into: context, policy: .merge)
        XCTAssertEqual(first.insertedProfiles, 0, "本机已有同 id 的档案，不该重复插入")
        XCTAssertGreaterThan(first.skippedExisting, 0, "跳过数没有统计，用户会以为没生效")

        let second = try DataRestorer.restore(backup, into: context, policy: .merge)
        XCTAssertEqual(second.totalInserted, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Profile>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DisputeCase>()).count, 1)
    }

    /// 覆盖模式必须清掉本机独有的数据 —— 否则它就不叫覆盖。
    func testReplaceRemovesLocalOnlyData() throws {
        try seedSampleData()
        let backup = try DataRestorer.parse(try DataExporter.build(context: context))

        let localOnly = Profile(name: "本机独有", relationshipType: RelationshipType.other.rawValue)
        context.insert(localOnly)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Profile>()).count, 2)

        _ = try DataRestorer.restore(backup, into: context, policy: .replace)

        let remaining = try context.fetch(FetchDescriptor<Profile>())
        XCTAssertEqual(remaining.count, 1, "覆盖模式没有清掉本机独有的档案")
        XCTAssertEqual(remaining.first?.name, "小林")
    }

    /// 覆盖恢复**不能**把登录账号一起删掉。
    ///
    /// ## 这条是补上一个漏掉的真实缺陷
    ///
    /// 第一版 `restore(.replace)` 直接调了 `DataEraser.eraseAll`，而它会
    /// `delete(model: User.self)`。后果：
    ///   1. 备份里没有 `User`（导出的是内容，不是账号），删了补不回来；
    ///   2. `AuthenticationService.currentUser` 是已落库的对象引用，
    ///      删行之后变悬空，「我的」页还要读 `currentUser?.phone`。
    ///
    /// 为什么之前的往返测试没发现：测试容器里从来没造过 `User` 行，
    /// 「删掉一个不存在的东西」当然不会报错。**样本缺失使断言恒真** ——
    /// 这个项目已经因为同一模式错过好几次。
    func testReplaceKeepAccountRow() throws {
        let account = User(phone: "13800138000")
        context.insert(account)

        try seedSampleData()
        let backup = try DataRestorer.parse(try DataExporter.build(context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<User>()), 1, "前置条件：账号行必须真的存在")

        _ = try DataRestorer.restore(backup, into: context, policy: .replace)

        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<User>()), 1,
            "覆盖恢复把登录账号删了 —— 备份里没有 User，删了就再也补不回来"
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<User>()).first?.phone, "13800138000")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Profile>()), 1, "内容应当照常恢复")
    }

    // MARK: - 拒绝坏输入

    /// 选错文件（比如导出的使用统计文本）必须明确拒绝，不能"导入 0 条说成功"。
    func testRejectsNonBackupFile() throws {
        let data = #"{"hello":"world"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DataRestorer.parse(data)) { error in
            XCTAssertEqual(error as? DataRestorer.Failure, .notABackup)
        }
    }

    /// 未来版本的备份必须拒绝：读懂一半就写入，比不导入更糟。
    func testRejectsNewerSchema() throws {
        let data = #"{"schemaVersion":99,"profiles":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try DataRestorer.parse(data)) { error in
            XCTAssertEqual(error as? DataRestorer.Failure, .unsupportedVersion(99))
        }
    }

    /// 早期备份（没有 schemaVersion、承诺没有 promisor）也要能导入。
    func testImportsLegacyBackupWithoutNewFields() throws {
        let json = """
        {
          "exportedAt": "2026-01-01T00:00:00Z",
          "appVersion": "1.0",
          "profiles": [
            {"id": "11111111-1111-1111-1111-111111111111", "name": "妈妈", "relationshipType": "family"}
          ],
          "promises": [
            {"id": "22222222-2222-2222-2222-222222222222", "content": "每周打一次电话", "status": "active",
             "records": []}
          ],
          "sessions": [],
          "disputes": []
        }
        """
        let backup = try DataRestorer.parse(Data(json.utf8))
        let report = try DataRestorer.restore(backup, into: context, policy: .merge)

        XCTAssertEqual(report.insertedProfiles, 1)
        XCTAssertEqual(report.insertedPromises, 1)
        let promise = try XCTUnwrap(try context.fetch(FetchDescriptor<Promise>()).first)
        XCTAssertEqual(promise.promisor, "user", "缺字段时应当走安全默认值，而不是丢弃整条")
        XCTAssertEqual(promise.promisee, "partner")
    }

    /// 头像照片跨设备恢复时文件不在 —— 要降级成默认色，并且**说出来**。
    func testMissingAvatarPhotoDegradesWithWarning() throws {
        let json = """
        {
          "schemaVersion": 1,
          "profiles": [
            {"id": "33333333-3333-3333-3333-333333333333", "name": "小林",
             "relationshipType": "partner", "avatar": "photo:not-on-this-device.jpg"}
          ]
        }
        """
        let backup = try DataRestorer.parse(Data(json.utf8))
        let report = try DataRestorer.restore(backup, into: context, policy: .merge)

        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<Profile>()).first)
        XCTAssertNil(profile.avatar, "照片文件不存在时不该留着死引用")
        XCTAssertFalse(report.warnings.isEmpty, "降级了却没有任何提示，用户会以为恢复完整")
    }

    /// 单条坏记录不能拖垮整份备份：能救的救回来，坏的计入跳过。
    ///
    /// 这条对应的真实场景是"备份被手改过一两个字符"。
    func testBadRowsAreSkippedWithoutLosingTheRest() throws {
        let json = """
        {
          "schemaVersion": 1,
          "profiles": [
            {"id": "not-a-uuid", "name": "坏行"},
            {"id": "44444444-4444-4444-4444-444444444444", "name": "好行"}
          ]
        }
        """
        let backup = try DataRestorer.parse(Data(json.utf8))
        XCTAssertEqual(backup.profiles.count, 2, "解析层不该在这里拦，交给恢复层逐条判定")

        let report = try DataRestorer.restore(backup, into: context, policy: .merge)
        XCTAssertEqual(report.insertedProfiles, 1)
        XCTAssertEqual(report.skippedExisting, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Profile>()).first?.name, "好行")
    }
}
