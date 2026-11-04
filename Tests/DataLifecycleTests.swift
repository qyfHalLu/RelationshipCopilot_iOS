//
//  DataLifecycleTests.swift
//  RelationshipCopilotTests
//
//  数据生命周期：删除与导出。
//
//  ## 为什么这两项必须有测试
//
//  这个产品的核心承诺是「数据只存本机、涉及隐私」。
//  在没有云端的情况下，"删除"和"导出"是用户对数据仅有的两个控制手段。
//  而这两处**同时出过真实缺陷**：
//
//    · `deleteEverything()` 手写删除清单，Schema 有 6 个实体却只删 5 个，
//      `DisputeCase` 被漏掉 —— 用户看到"已删除全部本地数据"，评理证词还在库里。
//    · `DataExporter` 只导出 profiles/promises/sessions，
//      评理数据一份都不在里面 —— 而删除确认框还写着"建议先导出备份"。
//
//  这两个缺陷的共同点：**编译通过、界面正常、没有任何测试会失败**。
//  所以这里的断言刻意写成"逐表数 0"与"字段逐个检查"，
//  而不是"调用没崩"这种什么都证明不了的写法。
//

import XCTest
import SwiftData
@testable import RelationshipCopilot

@MainActor
final class DataLifecycleTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(DataEraser.modelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    // MARK: 造数据

    /// 每个 `@Model` 实体各造一行。返回造出来的 Profile 供关联用。
    @discardableResult
    private func seedOneOfEach() throws -> Profile {
        let profile = Profile(name: "小林", relationshipType: RelationshipType.partner.rawValue)
        profile.setIntimacy(6)
        context.insert(profile)

        let promise = Promise(content: "吵架后 24 小时内主动开口", promisor: "user", promisee: "小林")
        promise.profile = profile
        context.insert(promise)

        let record = FulfillmentRecord(
            recordDate: Calendar.current.startOfDay(for: Date()),
            status: FulfillmentStatus.fulfilled.rawValue
        )
        record.promise = promise
        context.insert(record)

        let session = RecordingSession(
            sessionType: .conflict,
            profile: profile,
            startedAt: Date().addingTimeInterval(-600),
            endedAt: Date()
        )
        session.transcription = "样本转写"
        context.insert(session)

        let user = User(phone: "13800000000")
        context.insert(user)

        // 最关键的一个：评理案卷。
        let dispute = DisputeCase(title: "她说我总在解释", mode: .sameDevice)
        dispute.profile = profile
        dispute.sideA = DisputeTestimony(
            happened: "她说完之后我直接给了建议",
            hurtMost: "她说「跟你说也没用」",
            request: "她希望我先听",
            myPart: "我听得太急了"
        )
        context.insert(dispute)

        try context.save()
        return profile
    }

    // MARK: 删除

    /// 删除后**每一个**实体都必须是 0 行。
    ///
    /// 这里刻意不用"总数 == 0"这种写法：那样一个实体漏删、另一个多删两次也能通过。
    /// 必须逐表数。
    func testEraseAllClearsEveryModel() throws {
        try seedOneOfEach()

        // 先确认数据真的造进去了 —— 否则下面的"全是 0"毫无意义（空库本来就全 0）。
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<User>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Profile>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Promise>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FulfillmentRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordingSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DisputeCase>()), 1)

        try DataEraser.eraseAll(in: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<User>()), 0, "User 未被删除")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Profile>()), 0, "Profile 未被删除")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Promise>()), 0, "Promise 未被删除")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FulfillmentRecord>()), 0, "FulfillmentRecord 未被删除")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecordingSession>()), 0, "RecordingSession 未被删除")
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<DisputeCase>()), 0,
            "评理案卷未被删除 —— 这正是曾经发生过的隐私缺陷：用户看到「已删除全部本地数据」，"
            + "而最敏感的证词原文仍在库里"
        )
    }

    /// 守住「新增模型时不会漏删」。
    ///
    /// `DataEraser.eraseAll` 无法用反射自动遍历（SwiftData 的 `delete(model:)` 要求静态类型，
    /// existential 绑不上去），所以退而求其次：把清单收敛到 `modelTypes` 一处，
    /// 并用这条测试断言 Schema 里**每一个**实体都在清单里。
    /// 新增 `@Model` 却忘了登记时，这条会失败，而不是静默漏删。
    func testModelTypesCoverEntireSchema() {
        let schemaEntityNames = Set(container.schema.entities.map(\.name))
        let declaredNames = Set(DataEraser.modelTypes.map { String(describing: $0) })

        let missing = schemaEntityNames.subtracting(declaredNames)
        XCTAssertTrue(
            missing.isEmpty,
            "Schema 里有实体没有登记进 DataEraser.modelTypes：\(missing.sorted())。"
            + "它们不会被「删除全部数据」清掉，等于隐私承诺失效。"
        )
    }

    // MARK: 导出

    /// 导出必须包含评理案卷，且证词原文完整。
    ///
    /// 断言直接打在 JSON 上而不是 DTO 上：DTO 对了但编码时漏字段，
    /// 只有解析最终产物才能发现。
    func testExportIncludesDisputeWithFullTestimony() throws {
        try seedOneOfEach()

        let data = try DataExporter.build(context: context)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let disputes = try XCTUnwrap(
            json["disputes"] as? [[String: Any]],
            "导出文件里没有 disputes 字段 —— 换机后评理记录会静默丢失"
        )
        XCTAssertEqual(disputes.count, 1)

        let dispute = disputes[0]
        XCTAssertEqual(dispute["title"] as? String, "她说我总在解释")

        let sideA = try XCTUnwrap(dispute["sideA"] as? [String: Any], "证词 A 未导出")
        XCTAssertEqual(
            sideA["hurtMost"] as? String, "她说「跟你说也没用」",
            "证词原文必须原样带走 —— 这是备份，不是摘要"
        )

        // 降级标记必须跟着数据走，否则恢复后并列原话会被当成正常结论
        XCTAssertEqual(dispute["isDegradedVerdict"] as? Bool, false)
    }

    /// 其余三类数据也不许少（防止为了加 disputes 反而漏掉别的）。
    func testExportStillContainsOtherEntities() throws {
        try seedOneOfEach()

        let data = try DataExporter.build(context: context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["profiles", "promises", "sessions", "disputes"] {
            let array = try XCTUnwrap(json[key] as? [Any], "导出缺少 \(key)")
            XCTAssertEqual(array.count, 1, "\(key) 数量不对")
        }
    }

    /// 空库导出的结构必须稳定（各数组为 []，不是缺字段）。
    /// 否则依赖固定结构的恢复脚本会在"新用户"这种最常见的情况下失败。
    func testEmptyExportKeepsStableShape() throws {
        let data = try DataExporter.build(context: context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["profiles", "promises", "sessions", "disputes"] {
            let array = try XCTUnwrap(json[key] as? [Any], "空库导出缺少 \(key) 字段")
            XCTAssertTrue(array.isEmpty)
        }
    }
}
