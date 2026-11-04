//
//  LogicTests.swift
//  RelationshipCopilotTests
//
//  修复报告 A5：原仓库没有任何测试 target，0 个 XCTest。
//  这里优先覆盖"纯逻辑且曾被写错"的部分。
//
//  改版说明：`RelationshipHealth` 已删除（见 Core/IntimacyScale.swift）。
//  它的 7 条用例中，测换算与档位的 4 条随实现一起删除 ——
//  **删掉的不是"没通过的测试"，是"测一个不该存在的功能"的测试**。
//  保留部分改为 `IntimacyScaleTests`（夹取幂等性 + 标签不暗示测量）。
//
//  这些用例不依赖 SwiftData / SwiftUI，跑得快、失败原因清晰。
//

import XCTest
@testable import RelationshipCopilot

final class IntimacyScaleTests: XCTestCase {

    // 说明：`RelationshipHealth` 及其 70...100 的"分数"已整体删除
    // （见 Core/IntimacyScale.swift 头部）。原测试类 7 条用例里，
    // 4 条测的是被删掉的换算与档位，2 条测的是夹取（保留），
    // 1 条测的是空集合平均（对应逻辑已内联到 AnalysisView，不再属于 Core）。

    func testClampAcceptsValidRange() {
        for value in 0...10 {
            XCTAssertEqual(IntimacyScale.clamp(value), value)
        }
    }

    /// 核心回归（原报告 R6）：旧版 setter 会把 intimacyScore 写成 -56 / -194。
    /// 现在任何输入都必须被夹回 0...10。
    func testClampRejectsCorruptedValues() {
        XCTAssertEqual(IntimacyScale.clamp(-42), 0)
        XCTAssertEqual(IntimacyScale.clamp(-194), 0)
        XCTAssertEqual(IntimacyScale.clamp(-1), 0)
        XCTAssertEqual(IntimacyScale.clamp(99), 10)
        XCTAssertEqual(IntimacyScale.clamp(Int.max), 10)
        XCTAssertEqual(IntimacyScale.clamp(Int.min), 0)
    }

    /// 修复必须幂等：跑两次和跑一次结果一样（DataMaintenance 每次启动都会调）。
    func testClampIsIdempotent() {
        for input in [-200, -1, 0, 5, 10, 200] {
            let once = IntimacyScale.clamp(input)
            let twice = IntimacyScale.clamp(once)
            XCTAssertEqual(once, twice, "输入 \(input) 的夹取不幂等")
        }
    }

    /// 标签必须覆盖 0...10 全部取值，且不出现评价性词汇。
    func testLabelCoversWholeRange() {
        var labels = Set<String>()
        for value in 0...10 {
            labels.insert(IntimacyScale.label(for: value))
        }
        // 0-1 段若干取值共享标签，因此只断言"覆盖了每一个合法输入"而不要求每值唯一
        XCTAssertFalse(labels.isEmpty)
        for value in 0...10 {
            XCTAssertFalse(
                IntimacyScale.label(for: value).isEmpty,
                "intimacy \(value) 没有标签"
            )
        }
        // 越界输入也必须返回标签而不是崩溃
        XCTAssertFalse(IntimacyScale.label(for: -5).isEmpty)
        XCTAssertFalse(IntimacyScale.label(for: 50).isEmpty)
    }

    /// 标签里不得出现"分""评""健康度"这类暗示测量的字眼。
    func testLabelDoesNotImplyMeasurement() {
        let forbidden = ["分", "评", "健康", "打分", "得分"]
        for value in 0...10 {
            let label = IntimacyScale.label(for: value)
            for word in forbidden {
                XCTAssertFalse(label.contains(word), "标签「\(label)」含暗示测量的字「\(word)」")
            }
        }
    }
}

final class FulfillmentStatsTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    private func day(_ offset: Int, from base: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: base))!
    }

    func testEmptyEntriesProduceZero() {
        let summary = FulfillmentStats.summarize(entries: [], referencesDate: Date(), calendar: calendar)
        XCTAssertEqual(summary.rate, 0)
        XCTAssertEqual(summary.streakDays, 0)
        XCTAssertNil(summary.lastCheckIn)
        XCTAssertEqual(summary.sampleCount, 0)
    }

    func testRateCountsPartialAsHalfAndSkipsPending() {
        let today = day(0)
        let entries = [
            FulfillmentEntry(day: today, status: .fulfilled),
            FulfillmentEntry(day: day(-1), status: .partial),
            FulfillmentEntry(day: day(-2), status: .missed),
            FulfillmentEntry(day: day(-3), status: .pending)
        ]
        let summary = FulfillmentStats.summarize(entries: entries, referencesDate: today, calendar: calendar)
        XCTAssertEqual(summary.sampleCount, 3, "pending 不计入分母")
        XCTAssertEqual(summary.fulfilledCount, 1)
        XCTAssertEqual(summary.partialCount, 1)
        XCTAssertEqual(summary.missedCount, 1)
        XCTAssertEqual(summary.rate, 0.5, accuracy: 0.0001)  // (1 + 0.5 + 0) / 3
    }

    func testStreakCountsConsecutiveFulfilledDaysEndingToday() {
        let today = day(0)
        let entries = [
            FulfillmentEntry(day: today, status: .fulfilled),
            FulfillmentEntry(day: day(-1), status: .fulfilled),
            FulfillmentEntry(day: day(-2), status: .fulfilled),
            FulfillmentEntry(day: day(-3), status: .missed),
            FulfillmentEntry(day: day(-4), status: .fulfilled)
        ]
        let summary = FulfillmentStats.summarize(entries: entries, referencesDate: today, calendar: calendar)
        XCTAssertEqual(summary.streakDays, 3)
    }

    func testStreakAllowsTodayUnchecked() {
        // 允许"今天还没打卡"从昨天开始算，避免早上一打开就显示 0 天
        let today = day(0)
        let entries = [
            FulfillmentEntry(day: day(-1), status: .fulfilled),
            FulfillmentEntry(day: day(-2), status: .fulfilled)
        ]
        let summary = FulfillmentStats.summarize(entries: entries, referencesDate: today, calendar: calendar)
        XCTAssertEqual(summary.streakDays, 2)
    }

    func testStreakIsZeroWhenYesterdayAndTodayMissing() {
        let today = day(0)
        let entries = [FulfillmentEntry(day: day(-3), status: .fulfilled)]
        XCTAssertEqual(
            FulfillmentStats.summarize(entries: entries, referencesDate: today, calendar: calendar).streakDays,
            0
        )
    }

    func testOverdueDetection() {
        let today = day(0)
        XCTAssertTrue(FulfillmentStats.isOverdue(deadline: day(-1), referencesDate: today, calendar: calendar))
        XCTAssertFalse(FulfillmentStats.isOverdue(deadline: day(0), referencesDate: today, calendar: calendar))
        XCTAssertFalse(FulfillmentStats.isOverdue(deadline: nil, referencesDate: today, calendar: calendar))
    }

    func testRecentDaysPadsMissingDays() {
        let today = day(0)
        let entries = [FulfillmentEntry(day: today, status: .fulfilled)]
        let recent = FulfillmentStats.recentDays(entries: entries, days: 7, referencesDate: today, calendar: calendar)
        XCTAssertEqual(recent.count, 7)
        XCTAssertEqual(recent.last?.status, .fulfilled)
        XCTAssertNil(recent.first?.status)
    }
}

final class AIResponseParserTests: XCTestCase {

    func testParsesPlainJSON() throws {
        let raw = """
        {"score": 82, "summary": "沟通还不错", "strengths": ["倾听"], \
        "improvements": ["少打断"], "suggestions": ["每天聊十分钟"], \
        "emotionalTrend": "上升", "communicationQuality": "良好"}
        """
        let parsed = try AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.score, 82)
        XCTAssertEqual(parsed.summary, "沟通还不错")
        XCTAssertEqual(parsed.strengths, ["倾听"])
        XCTAssertEqual(parsed.improvements, ["少打断"])
        XCTAssertEqual(parsed.suggestions, ["每天聊十分钟"])
        XCTAssertEqual(parsed.emotionalTrend, "上升")
        XCTAssertEqual(parsed.communicationQuality, "良好")
    }

    func testParsesFencedJSONWithSurroundingProse() throws {
        let raw = """
        好的，下面是分析结果：
        ```json
        {"score": 76, "summary": "有点紧张"}
        ```
        希望有帮助。
        """
        let parsed = try AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.score, 76)
    }

    func testMissingScoreStaysNilInsteadOfBeingFabricated() throws {
        // 关键回归：旧实现用 `?? 75` 补齐，会静默编造关系评分
        let raw = #"{"summary": "信息不足", "suggestions": ["多提供一些细节"]}"#
        let parsed = try AIResponseParser.parse(raw)
        XCTAssertNil(parsed.score)
        XCTAssertTrue(parsed.hasUsableContent)
    }

    func testScoreAsStringIsAccepted() throws {
        let parsed = try AIResponseParser.parse(#"{"score": "88", "summary": "好"}"#)
        XCTAssertEqual(parsed.score, 88)
    }

    func testOutOfRangeScoreIsDropped() throws {
        let parsed = try AIResponseParser.parse(#"{"score": 480, "summary": "异常值"}"#)
        XCTAssertNil(parsed.score, "越界分数应该丢弃而不是截断成 100")
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try AIResponseParser.parse("   "))
    }

    func testNonJSONThrows() {
        XCTAssertThrowsError(try AIResponseParser.parse("抱歉，我无法分析这段内容。"))
    }

    func testJSONWithoutUsableFieldsThrows() {
        XCTAssertThrowsError(try AIResponseParser.parse("{}"))
    }

    func testNestedBracesInStringValuesDoNotBreakExtraction() throws {
        let raw = #"{"summary": "他说了 { 这个符号 }", "score": 70}"#
        let parsed = try AIResponseParser.parse(raw)
        XCTAssertEqual(parsed.score, 70)
        XCTAssertEqual(parsed.summary, "他说了 { 这个符号 }")
    }
}

final class QuotaPolicyTests: XCTestCase {

    func testRemainingAndExhaustion() {
        let policy = QuotaPolicy(limit: 10)
        XCTAssertEqual(policy.remaining(used: 0), 10)
        XCTAssertEqual(policy.remaining(used: 9), 1)
        XCTAssertEqual(policy.remaining(used: 10), 0)
        XCTAssertTrue(policy.isExhausted(used: 10))
        XCTAssertTrue(policy.isExhausted(used: 99))
        XCTAssertFalse(policy.isExhausted(used: 9))
    }

    func testNegativeUsageDoesNotInflateQuota() {
        let policy = QuotaPolicy(limit: 3)
        XCTAssertEqual(policy.remaining(used: -5), 3)
    }

    func testZeroLimitIsAlwaysExhausted() {
        let policy = QuotaPolicy(limit: 0)
        XCTAssertTrue(policy.isExhausted(used: 0))
    }

    func testResetAcrossDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: Date())

        XCTAssertTrue(QuotaPolicy.shouldReset(lastResetDay: nil, today: today, calendar: calendar))
        XCTAssertFalse(
            QuotaPolicy.shouldReset(lastResetDay: today, today: today.addingTimeInterval(3600), calendar: calendar)
        )
        XCTAssertTrue(
            QuotaPolicy.shouldReset(
                lastResetDay: calendar.date(byAdding: .day, value: -1, to: today),
                today: today,
                calendar: calendar
            )
        )
    }
}

final class ValidationTests: XCTestCase {

    func testValidPhoneNumbers() {
        XCTAssertTrue(Validation.isValidPhone("13800000000"))
        XCTAssertTrue(Validation.isValidPhone("19912345678"))
        XCTAssertTrue(Validation.isValidPhone("138 0000 0000"))
    }

    func testInvalidPhoneNumbers() {
        XCTAssertFalse(Validation.isValidPhone(""))
        XCTAssertFalse(Validation.isValidPhone("1380000000"))     // 10 位
        XCTAssertFalse(Validation.isValidPhone("138000000000"))   // 12 位
        XCTAssertFalse(Validation.isValidPhone("12800000000"))    // 第二位非法
        XCTAssertFalse(Validation.isValidPhone("abcdefghijk"))
    }

    func testNormalizeStripsCountryCode() {
        XCTAssertEqual(Validation.normalizePhone("+86 138 0000 0000"), "13800000000")
        XCTAssertEqual(Validation.normalizePhone("8613800000000"), "13800000000")
    }

    func testCodeValidation() {
        XCTAssertTrue(Validation.isValidCode("123456"))
        XCTAssertFalse(Validation.isValidCode("12345"))
        XCTAssertFalse(Validation.isValidCode("1234567"))
    }

    func testDigitsOnlyTruncates() {
        XCTAssertEqual(Validation.digitsOnly("1a2b3c4d5e6f7g", maxLength: 6), "123456")
    }

    func testOptionalTextNormalizesWhitespace() {
        XCTAssertNil(Validation.optionalText("   "))
        XCTAssertEqual(Validation.optionalText(" 你好 "), "你好")
    }
}

final class RelationshipTypeTests: XCTestCase {

    func testSpouseIsNotMappedToOther() {
        // 回归：旧的 ProfilesView 手写映射漏了 spouse，配偶显示成「其他」
        XCTAssertEqual(RelationshipType.spouse.displayName, "配偶")
        XCTAssertEqual(RelationshipType.parse("spouse"), .spouse)
    }

    func testAllCasesHaveDistinctDisplayNames() {
        let names = RelationshipType.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "中文名不应重复")
        XCTAssertFalse(names.contains(""))
    }

    func testUnknownRawValueFallsBackToOther() {
        XCTAssertEqual(RelationshipType.parse("lover"), .other)
        XCTAssertEqual(RelationshipType.parse(nil), .other)
    }

    func testIntimateFlag() {
        XCTAssertTrue(RelationshipType.partner.isIntimate)
        XCTAssertTrue(RelationshipType.spouse.isIntimate)
        XCTAssertFalse(RelationshipType.friend.isIntimate)
    }
}
