//
//  AvatarAndRelationshipTests.swift
//  RelationshipCopilotTests
//
//  本轮改版的回归测试：
//   ① 头像颜色的解析与兼容（旧 `"color:0"` 索引格式必须还能读）
//   ② 自定义关系名称的显示回退
//   ③ 产品文案里不该再出现默认性别的指代
//
//  ## 为什么这些值得单独测
//
//  ① 和 ② 都是"多形态字符串"的解析：`Profile.avatar` 一个字段承载
//  颜色 hex、旧索引、照片文件名三种含义。这类解析的失效方式很安静 ——
//  解析不出来就回退默认值，界面看着正常，只是用户的选择消失了。
//  这正是本轮要修的那个 bug 的形态（写了不读），所以必须钉住。
//
//  ③ 是产品口径。它不像崩溃那样会自己暴露，只会在某次文案改动后
//  悄悄回来，所以用断言把它固定。
//

import XCTest
@testable import RelationshipCopilot

final class AvatarStorageTests: XCTestCase {

    // MARK: 解析

    func testParsesColorHex() {
        XCTAssertEqual(AvatarStorage.parse("color:6366F1"), .color("6366F1"))
    }

    func testParsesPhotoName() {
        XCTAssertEqual(AvatarStorage.parse("photo:ABC-123.jpg"), .photo("ABC-123.jpg"))
    }

    /// 旧数据兼容：改成 hex 之前存的是调色板索引。
    ///
    /// 这条是升级用户的关键 —— 如果不认索引，老用户保存过的颜色会在
    /// 升级后全部变成默认色，而他们不会知道为什么。
    func testParsesLegacyIndexFormat() {
        let parsed = AvatarStorage.parse("color:0")
        guard case .color(let hex)? = parsed else {
            return XCTFail("旧索引格式没被识别：\(String(describing: parsed))")
        }
        XCTAssertEqual(hex.count, 6, "应转成 6 位 hex，实际 \(hex)")
        XCTAssertNotNil(AvatarStorage.color(fromHex: hex), "转换出的 hex 无法构造颜色")
    }

    func testLegacyIndexIsStable() {
        // 同一个索引每次必须给出同一个颜色，否则老用户头像会每次启动都变。
        let a = AvatarStorage.parse("color:2")
        let b = AvatarStorage.parse("color:2")
        XCTAssertEqual(a, b)
    }

    /// 索引越界不能崩。
    ///
    /// `legacyPalette[index % count]` 里的取模就是为这个写的，
    /// 但只有真的用一个越界值测过才算数。
    func testLegacyIndexOutOfRangeDoesNotCrash() {
        XCTAssertNotNil(AvatarStorage.parse("color:999"))
        XCTAssertNotNil(AvatarStorage.parse("color:999999"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(AvatarStorage.parse(nil))
        XCTAssertNil(AvatarStorage.parse(""))
        XCTAssertNil(AvatarStorage.parse("随便一个字符串"))
        XCTAssertNil(AvatarStorage.parse("photo:"))
        // 旧版的空颜色值
        XCTAssertNil(AvatarStorage.parse("color:"))
    }

    // MARK: 编码

    func testEncodeRoundTrips() {
        let hex = "8B5CF6"
        XCTAssertEqual(AvatarStorage.parse(AvatarStorage.encode(colorHex: hex)), .color(hex))

        let photo = "X.jpg"
        XCTAssertEqual(AvatarStorage.parse(AvatarStorage.encode(photoName: photo)), .photo(photo))
    }

    // MARK: 颜色构造

    /// 非法 hex 必须返回 nil，而不是黑色。
    ///
    /// `UIColor(hex:)` 对坏输入静默返回黑色（ThemeManager.swift），
    /// 用在这里会让头像变成一个黑圆 —— 看起来像设计，实际是数据坏了。
    func testInvalidHexReturnsNilNotBlack() {
        XCTAssertNil(AvatarStorage.color(fromHex: "zzz"))
        XCTAssertNil(AvatarStorage.color(fromHex: ""))
        XCTAssertNil(AvatarStorage.color(fromHex: "12"), "两位不是合法颜色")
        // 合法的要能构造出来
        XCTAssertNotNil(AvatarStorage.color(fromHex: "6366F1"))
        XCTAssertNotNil(AvatarStorage.color(fromHex: "6366F1FF"), "8 位带 alpha 也要支持")
    }

    // MARK: 默认色

    func testDeterministicHexIsStable() {
        let id = UUID()
        XCTAssertEqual(
            AvatarStorage.deterministicHex(for: id),
            AvatarStorage.deterministicHex(for: id),
            "同一 UUID 必须给出同一个颜色"
        )
    }

    func testDeterministicHexDistributes() {
        // 0 样本时循环里的断言恒真，所以先要求样本数。
        let ids = (0..<200).map { _ in UUID() }
        XCTAssertEqual(ids.count, 200)

        let colors = Set(ids.map { AvatarStorage.deterministicHex(for: $0) })
        XCTAssertGreaterThan(
            colors.count, 5,
            "200 个 UUID 只落到 \(colors.count) 种颜色，哈希分布有问题"
        )
    }

    func testPaletteHasEnoughColors() {
        // 原来 6 个，在"每人一个颜色"的场景下必然撞色。
        XCTAssertGreaterThanOrEqual(AvatarStorage.paletteHex.count, 10)
        XCTAssertEqual(
            Set(AvatarStorage.paletteHex).count,
            AvatarStorage.paletteHex.count,
            "色板里有重复颜色"
        )
        for hex in AvatarStorage.paletteHex {
            XCTAssertNotNil(
                AvatarStorage.color(fromHex: hex),
                "色板里的 \(hex) 构造不出颜色"
            )
        }
    }
}

// MARK: - 自定义关系名称

final class RelationshipLabelTests: XCTestCase {

    private func makeProfile(
        _ type: RelationshipType,
        custom: String? = nil
    ) -> Profile {
        let profile = Profile(name: "测试", relationshipType: type.rawValue)
        profile.customRelationshipName = custom
        return profile
    }

    func testOtherUsesCustomName() {
        let profile = makeProfile(.other, custom: "舅舅")
        XCTAssertEqual(profile.relationshipLabel, "舅舅")
    }

    func testOtherFallsBackWhenCustomIsBlank() {
        // 只填空白等同于没填 —— 否则列表里会出现一个空白的副标题。
        XCTAssertEqual(makeProfile(.other, custom: "   ").relationshipLabel, "其他")
        XCTAssertEqual(makeProfile(.other, custom: nil).relationshipLabel, "其他")
    }

    /// 自定义名称只在「其他」下生效。
    ///
    /// 否则会出现"关系选了配偶、副标题却显示舅舅"这种自相矛盾的状态
    /// （详情页切换关系类型时最容易留下这种残留值）。
    func testCustomNameIgnoredForNonOther() {
        let profile = makeProfile(.spouse, custom: "舅舅")
        XCTAssertEqual(profile.relationshipLabel, "配偶")
    }
}

// MARK: - 产品文案不含默认性别

/// 守住「不默认对方性别」这条产品口径。
///
/// 只扫用户可见的字符串字面量，注释和测试数据不算 ——
/// 注释里出现「他」是在解释历史，不是产品文案。
final class GenderNeutralCopyTests: XCTestCase {

    /// 这些文件里有大量用户可见文案。
    ///
    /// 2026-11-05：原来只有 5 个文件，等于给"别处写了「他」"留了一片盲区。
    /// 后来发现真正的重灾区根本不在那 5 个里 —— `AIAssistService` 的提示词
    /// 用「他可能会觉得……」给模型做示例，模型会照抄。
    /// 所以现在覆盖全部会产出用户可见文本的文件（视图 + 提示词 + 文案常量）。
    private static let filesToScan = [
        // Core：文案与提示词
        "Core/GuidedRepair.swift",
        "Core/DisputePrompt.swift",
        "Core/DisputeVerdict.swift",
        "Core/SafetyScreen.swift",
        "Core/WaitingCopy.swift",
        // Services：提示词与错误文案
        "Services/AIAssistService.swift",
        "Services/AIService.swift",
        "Services/InviteService.swift",
        "Services/AuthenticationService.swift",
        // 首页与工具
        "Presentation/Views/ContentView.swift",
        "Presentation/Views/QuickTools/QuickToolsView.swift",
        "Presentation/Views/QuickTools/GuidedRepairView.swift",
        // 评理
        "Presentation/Views/Dispute/DisputeListView.swift",
        "Presentation/Views/Dispute/DisputeFlowView.swift",
        "Presentation/Views/Dispute/DisputeVerdictView.swift",
        "Presentation/Views/Dispute/RemoteHandoverView.swift",
        "Presentation/Views/Dispute/TestimonyEditor.swift",
        // 其他页面
        "Presentation/Views/Promises/PromisesView.swift",
        "Presentation/Views/Profiles/ProfilesView.swift",
        "Presentation/Views/Profiles/ProfileDetailView.swift",
        "Presentation/Views/Profiles/AddProfileView.swift",
        "Presentation/Views/Settings/MeView.swift",
        "Presentation/Views/Settings/SettingsView.swift",
        "Presentation/Views/Settings/LegalViews.swift",
        "Presentation/Views/Auth/AuthenticationView.swift",
        "Presentation/Views/Recording/RecordingView.swift",
        "Presentation/Views/Analysis/AnalysisView.swift",
        "Presentation/Views/Analysis/SessionDetailView.swift"
    ]


    /// 这些词里的 `他` 不是性别指代，扫描前先剔除。
    ///
    /// 只收真正中性的词，不要为了"让测试通过"往里塞 ——
    /// 每塞一个词，就少一块覆盖。收词依据是《现代汉语词典》里
    /// `他` 不指代具体第三方的固定搭配。
    private static let neutralCompounds = [
        "其他", "他人", "他乡", "他日", "他方", "他处", "他国", "他者",
        "他律", "他杀", "他用", "他山之石", "利他", "排他", "无他", "他证",
        "他年"
    ]

    /// 把一个字面量里"中性的 他"抹掉，剩下的才是需要检查的。
    static func strippingNeutralCompounds(_ literal: String) -> String {
        var out = literal
        for word in Self.neutralCompounds {
            out = out.replacingOccurrences(of: word, with: "")
        }
        return out
    }

    func testUserFacingCopyIsGenderNeutral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // 仓库根

        var offenders: [String] = []
        var scannedFiles = 0
        var skippedBlocks = 0
        var scannedLines = 0

        for relative in Self.filesToScan {
            let url = root.appendingPathComponent(relative)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scannedFiles += 1

            let result = Self.scan(source)
            skippedBlocks += result.skippedBlocks
            scannedLines += result.scannedLines
            for hit in result.hits {
                offenders.append("\(relative):\(hit.line) \(hit.text)")
            }
        }

        // 前提校验：一个文件都没读到的话，下面的断言恒真，等于没测。
        XCTAssertGreaterThanOrEqual(
            scannedFiles, 3,
            "只扫到 \(scannedFiles) 个文件，扫描逻辑可能失效了"
        )
        // 同理：一行都没扫到的话，「没有 offender」也是假的。
        XCTAssertGreaterThanOrEqual(
            scannedLines, 500,
            "只扫到 \(scannedLines) 行，扫描逻辑可能失效了"
        )
        // 豁免区块必须真的被识别到，否则「豁免」这件事就变成了自欺。
        XCTAssertGreaterThanOrEqual(
            skippedBlocks, 2,
            "只识别到 \(skippedBlocks) 个豁免区块，标记解析可能失效了"
        )
        XCTAssertTrue(
            offenders.isEmpty,
            "产品文案里仍有默认性别的指代（应改为 TA）：\n" + offenders.joined(separator: "\n")
        )
    }

    /// 扫描结果。
    struct ScanResult {
        var hits: [(line: Int, text: String)] = []
        var skippedBlocks = 0
        var scannedLines = 0
    }

    /// 逐行扫描一份源码：跳过豁免块、去掉 `//` 之后的注释，再看剩下部分有没有性别指代。
    ///
    /// ## 为什么不再只扫「单行字符串字面量」
    ///
    /// 第一版用 `"` 配对切字面量，对**多行字符串**（`"""`）是失效的：
    /// 提示词正文里只要出现一个引号（例如给模型的示例 `用"他可能会觉得……"`），
    /// 配对就错位，**恰好被引号夹住的那句话会被当成"不在字面量里"而跳过**。
    ///
    /// 实测证据：把 `他可能会觉得` 放回 `AIAssistService` 的提示词里，
    /// 旧扫描器 0 命中、测试照样全绿。而提示词里的一句话会被模型照抄进输出 ——
    /// 那是最该拦的地方。
    ///
    /// 现在改为按行扫描全文：注释是解释，不是产品文案，去掉；
    /// 代码里的中文极少，误报风险远小于漏报。
    static func scan(_ source: String) -> ScanResult {
        var result = ScanResult()
        var exempt = false

        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            if raw.contains("gender-neutral-scan:off") {
                exempt = true
                result.skippedBlocks += 1
                continue
            }
            if raw.contains("gender-neutral-scan:on") {
                exempt = false
                continue
            }
            if exempt { continue }

            // 行尾注释不算文案
            let code = raw.components(separatedBy: "//").first ?? ""
            if code.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            result.scannedLines += 1

            let checked = strippingNeutralCompounds(code)
            if checked.contains("他") || checked.contains("她") {
                result.hits.append((index + 1, String(code.prefix(60))))
            }
        }
        return result
    }

    /// 反向验证：扫描器必须能看见**多行字符串**里的性别指代。
    ///
    /// 这条是给上面那段注释兜底的 —— 没有它，谁都可以把扫描逻辑
    /// "简化"回只认单行字面量，而测试依然全绿。
    func testScannerSeesMultiLinePromptText() {
        let sample = """
        enum P {
            static let prompt = \"\"\"
            任务：不要说「他可能会觉得……」。
            \"\"\"
        }
        """
        let result = Self.scan(sample)
        XCTAssertEqual(result.hits.count, 1, "多行提示词里的「他」没有被扫到：\(result.hits)")
        XCTAssertEqual(result.hits.first?.line, 3, "行号不对，报错时无法定位")

        // 注释里的「他」不该被算成文案
        let commented = """
        // 这里解释历史时提到他，不算产品文案
        let x = 1
        """
        XCTAssertTrue(Self.scan(commented).hits.isEmpty, "把注释里的「他」当成了产品文案")

        // 豁免块仍然要生效
        let exempted = """
        // gender-neutral-scan:off
        let needles = ["他先", "她先"]
        // gender-neutral-scan:on
        """
        XCTAssertTrue(Self.scan(exempted).hits.isEmpty, "豁免块没有生效")
        XCTAssertEqual(Self.scan(exempted).skippedBlocks, 1)
    }

    /// 反向验证：确认"剔除中性复合词"没有把真正该抓的也一起放过。
    ///
    /// 不做这一步的话，`neutralCompounds` 可以被随手加词加到测试永远绿，
    /// 而这正是本测试第一版的失败方式。
    func testGenderScannerStillCatchesRealPronouns() {
        XCTAssertTrue(Self.strippingNeutralCompounds("怕他发火").contains("他"))
        XCTAssertTrue(Self.strippingNeutralCompounds("错不在他").contains("他"))
        XCTAssertTrue(Self.strippingNeutralCompounds("他有没有把话说完").contains("他"))
        XCTAssertTrue(Self.strippingNeutralCompounds("她先开口的").contains("她"))

        // 中性词必须被剔除干净
        XCTAssertFalse(Self.strippingNeutralCompounds("其他人都走了").contains("他"))
        XCTAssertFalse(Self.strippingNeutralCompounds("他人的感受").contains("他"))
        XCTAssertFalse(Self.strippingNeutralCompounds("他乡遇故知").contains("他"))

        // 中性词与真代词混在一起时，不能连坐
        XCTAssertTrue(Self.strippingNeutralCompounds("其他人怎么想，他说了什么").contains("他"))
    }


}

// MARK: - 输出侧性别兜底

/// 提示词禁止模型假定性别，但提示词管不住模型 —— 必须有客户端复核。
///
/// 这条测试的存在理由来自一次真实事故：截图核验时发现判词里写着
/// 「你在争……，她在争……」。当时所有单测全绿，因为没有任何测试看过输出内容。
/// 用户的原话是「不默认他人的性别」，模型自己发挥一句就等于违反了这条。
final class VerdictGenderGuardTests: XCTestCase {

    private func verdict(_ text: String) -> DisputeVerdict {
        DisputeVerdict(
            reframe: text,
            needA: "我不是不在乎，我只是不会说。",
            needB: "我不是要方案，我只是想被听见。",
            stuckPoint: "你们卡在谁先开口上。",
            solvability: .solvable,
            action: "这周找一次，只说一句「那一定很难受」。"
        )
    }

    /// 「她」出现即违规。
    func testFlagsFemalePronoun() {
        let v = verdict("你在争「怎么解决问题」，她在争「有没有人接住我」。")
        XCTAssertTrue(v.genderedHits.contains("她"), "「她」应当被拦下")
        XCTAssertFalse(v.passesContentGuards, "含性别代词的结果不应通过内容校验")
    }

    /// 「他」作为代词出现时违规。
    func testFlagsMalePronoun() {
        let v = verdict("他给建议是因为在乎，不是不耐烦。")
        XCTAssertTrue(v.genderedHits.contains("他"), "「他」作为代词应当被拦下")
    }

    /// 但「其他 / 他人 / 他日」里的「他」不是代词，不能误拦。
    ///
    /// 这是本检查最容易写错的地方：如果偷懒用 `contains("他")`，
    /// 大量正常判词会被判为违规，降级路径被频繁触发，
    /// 最后一定会有人把整个检查关掉 —— 那就等于没做。
    func testDoesNotFlagHeAsOtherWord() {
        let cases = [
            "你们卡在「其他事都比这件事重要」这个感受上。",
            "这个动作不需要他人配合也能做完。",
            "他日若再遇到同样的情形，先停十秒。"
        ]
        for text in cases {
            let v = verdict(text)
            XCTAssertTrue(v.genderedHits.isEmpty, "「\(text)」不该被判违规，实际命中 \(v.genderedHits)")
        }
    }

    /// 「他们」一并拦下：它既带复数也常被当默认性别用。
    func testFlagsTheyPronoun() {
        let v = verdict("你们卡在同一处，他们都不肯先开口。")
        XCTAssertTrue(v.genderedHits.contains("他们"))
    }

    /// 两种模式的提示词都必须带上性别约束。
    ///
    /// 这条来自一次真实的漏改：我先给同机模式加了约束，单机模式漏了 ——
    /// 单测全绿，因为没有任何测试去检查「提示词里有没有这段话」。
    /// 两个模式各自是一份独立的字符串，改一份不会自动同步另一份，
    /// 所以必须逐个断言，而不是「加一处以为就够了」。
    func testBothPromptModesCarryGenderRule() {
        let modes: [(String, String)] = [
            ("同机", DisputePrompt.systemPrompt(mode: .sameDevice, relationshipLabel: "伴侣")),
            ("单机", DisputePrompt.systemPrompt(mode: .solo, relationshipLabel: "伴侣"))
        ]
        for (name, prompt) in modes {
            XCTAssertTrue(prompt.contains("不得假定性别"), "\(name)模式的提示词缺少性别约束段")
            XCTAssertTrue(prompt.contains("「他」「她」"), "\(name)模式没把禁用词写清，模型不会知道禁什么")
            // 源码标记不能漏进提示词：那会让模型看到 `// gender-neutral-scan:off` 这种东西。
            XCTAssertFalse(prompt.contains("gender-neutral-scan"), "\(name)模式的提示词混进了源码标记")
        }
    }

    /// 全用 TA 的合规文本必须放行 —— 否则守门会把正确输出也拦掉。
    func testPassesGenderNeutralVerdict() {
        let v = verdict("你在争「怎么把问题解决掉」，TA 在争「有没有人先接住我」。")
        XCTAssertTrue(v.genderedHits.isEmpty, "合规文本不该命中，实际 \(v.genderedHits)")
        XCTAssertTrue(v.passesContentGuards, "合规文本应当通过内容校验")
    }
}

// MARK: - 扫描器自身的行为（反向验证）

/// 上面那个守门测试如果本身失效，报绿是没意义的。
///
/// 这几条专门喂**故意的坏输入**，确认扫描器能抓到、也能正确地只放过标记区块。
///
/// 2026-11-05：这三条原先测的是 `strippingExemptBlocks` + `stringLiterals`
/// 那套"先切字面量再扫"的旧管线 —— 而主测试已经改成按行扫描。
/// 结果是它们在保护一段**没人用的代码**，主流程坏了也不会红。
/// 现在统一改测 `scan(_:)`。
final class GenderNeutralScannerTests: XCTestCase {

    private typealias Scanner = GenderNeutralCopyTests

    /// 正向：没有标记时，性别词必须被扫出来。
    func testCatchesGenderedCopyWithoutMarker() {
        let source = """
        let a = "你让他很为难"
        let b = "把功劳给她"
        """
        let result = Scanner.scan(source)
        XCTAssertEqual(result.skippedBlocks, 0, "这段没有标记，不该识别出豁免区块")
        XCTAssertEqual(result.hits.count, 2, "故意的两处性别词应当各命中一次，实际 \(result.hits)")
    }

    /// 反向：加了标记的区块必须被整体剔除，标记外的内容仍要保留。
    func testExemptBlockIsRemovedAndOutsideStillScanned() {
        let source = """
        let outside = "你让她很难受"
        // gender-neutral-scan:off
        let inside = "她也", "她先"
        // gender-neutral-scan:on
        let tail = "谁让她"
        """
        let result = Scanner.scan(source)
        XCTAssertEqual(result.skippedBlocks, 1, "应当识别到恰好 1 个豁免区块")
        XCTAssertEqual(result.hits.count, 2, "标记外那两行应当命中，实际 \(result.hits)")
        XCTAssertFalse(
            result.hits.contains { $0.text.contains("她也") },
            "豁免区块内的内容被当成文案了"
        )
    }

    /// 边界：`:on` 之后必须恢复扫描，否则半张文件会失明。
    func testMarkerTurnsScanningBackOn() {
        let source = """
        // gender-neutral-scan:off
        let a = "她先"
        // gender-neutral-scan:on
        let b = "让他"
        """
        let result = Scanner.scan(source)
        XCTAssertEqual(result.skippedBlocks, 1)
        XCTAssertEqual(result.hits.count, 1, "标记关闭后应当恢复扫描，实际 \(result.hits)")
        XCTAssertTrue(result.hits[0].text.contains("让他"))
    }
}
