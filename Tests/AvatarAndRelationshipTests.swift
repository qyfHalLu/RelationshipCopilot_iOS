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
    private static let filesToScan = [
        "Core/GuidedRepair.swift",
        "Core/DisputePrompt.swift",
        "Core/DisputeVerdict.swift",
        "Presentation/Views/QuickTools/GuidedRepairView.swift",
        "Presentation/Views/Promises/PromisesView.swift"
    ]

    /// 明确的性别化指代。
    ///
    /// 刻意不扫单独的「他」：汉语里「其他」「他人」「他」的用法混在一起，
    /// 单字扫描必然误报（本项目已经因为"关键词存在性"这类断言错过三次）。
    /// 这里只挑出**确定指代第三方个体**的组合。
    private static let genderedPhrases = [
        "她", "陪她", "对她", "让她", "给她", "和她", "跟她",
        "他先", "让他", "对她好"
    ]

    func testUserFacingCopyIsGenderNeutral() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // 仓库根

        var offenders: [String] = []
        var scannedFiles = 0
        var skippedBlocks = 0

        for relative in Self.filesToScan {
            let url = root.appendingPathComponent(relative)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scannedFiles += 1

            let (scannable, blocks) = Self.strippingExemptBlocks(source)
            skippedBlocks += blocks

            // 只看字符串字面量，跳过注释。
            for literal in Self.stringLiterals(in: scannable) {
                for phrase in Self.genderedPhrases where literal.contains(phrase) {
                    offenders.append("\(relative): 「\(literal.prefix(40))」含「\(phrase)」")
                }
            }
        }

        // 前提校验：一个文件都没读到的话，下面的断言恒真，等于没测。
        XCTAssertGreaterThanOrEqual(
            scannedFiles, 3,
            "只扫到 \(scannedFiles) 个文件，扫描逻辑可能失效了"
        )
        // 豁免区块必须真的被识别到，否则本测试在悄悄扫全文，
        // 而「豁免」这件事就变成了自欺。
        XCTAssertGreaterThanOrEqual(
            skippedBlocks, 2,
            "只识别到 \(skippedBlocks) 个豁免区块，标记解析可能失效了"
        )
        XCTAssertTrue(
            offenders.isEmpty,
            "产品文案里仍有默认性别的指代（应改为 TA）：\n" + offenders.joined(separator: "\n")
        )
    }

    /// 剔除显式声明「此处含性别词是刻意的」的区块。
    ///
    /// 背景：本测试第一次跑就报了 8 条，其中 7 条来自**输入侧检测词表**
    /// （`blameMarkers` 收用户手写时会打的「她先」，`forbiddenPhrases` 拦模型输出的「她错了」）。
    /// 那两处**必须**保留性别词，否则功能漏检。
    ///
    /// 所以不能靠「人工记住哪些文件别扫」——那种豁免会随时间失效且无人察觉。
    /// 改成让源码自己声明：`gender-neutral-scan:off` 到 `:on` 之间跳过。
    /// 标记写在注释里，因此不会进入字符串字面量。
    // 从 private 放开到 internal：为了让下面的反向验证能直接调它。
    // 「新增断言要做反向验证」是本项目已付过代价的规矩 ——
    // 不故意让条件失败一次，就排除不掉「恒真」。
    static func strippingExemptBlocks(_ source: String) -> (String, Int) {
        var output = ""
        var exempt = false
        var blocks = 0
        for line in source.components(separatedBy: "\n") {
            if line.contains("gender-neutral-scan:off") {
                exempt = true
                blocks += 1
                continue
            }
            if line.contains("gender-neutral-scan:on") {
                exempt = false
                continue
            }
            if !exempt { output += line + "\n" }
        }
        return (output, blocks)
    }

    /// 取出源码里的 `"..."` 字面量。
    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var current: String?
        for ch in source {
            if ch == "\"" {
                if let open = current {
                    literals.append(open)
                    current = nil
                } else {
                    current = ""
                }
                continue
            }
            if current != nil { current?.append(ch) }
        }
        return literals
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
final class GenderNeutralScannerTests: XCTestCase {

    private typealias Scanner = GenderNeutralCopyTests

    /// 正向：没有标记时，性别词必须被扫出来。
    func testCatchesGenderedCopyWithoutMarker() {
        let source = """
        let a = "你让他很为难"
        let b = "把功劳给她"
        """
        let (scannable, blocks) = Scanner.strippingExemptBlocks(source)
        XCTAssertEqual(blocks, 0, "这段没有标记，不该识别出豁免区块")

        let literals = Scanner.stringLiterals(in: scannable)
        XCTAssertGreaterThanOrEqual(literals.count, 2, "字面量都没解析出来，后面的断言会恒真")

        let hits = literals.flatMap { lit in
            ["让她", "给她", "和他", "让他"].filter { lit.contains($0) }
        }
        XCTAssertEqual(hits.count, 2, "故意写的两处性别词应当各命中一次，实际命中 \(hits)")
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
        let (scannable, blocks) = Scanner.strippingExemptBlocks(source)
        XCTAssertEqual(blocks, 1, "应当识别到恰好 1 个豁免区块")

        XCTAssertFalse(scannable.contains("她也"), "豁免区块内的内容没被剔除")
        XCTAssertTrue(scannable.contains("你让她很难受"), "豁免区块外的内容被误删了")
        XCTAssertTrue(scannable.contains("谁让她"), "标记之后的内容应当恢复扫描")
    }

    /// 边界：标记只开关一次时，不能把后半段整段吞掉。
    func testUnclosedMarkerDoesNotLeakIntoRestOfFile() {
        let source = """
        // gender-neutral-scan:off
        let a = "她先"
        // gender-neutral-scan:on
        let b = "让他"
        """
        let (scannable, blocks) = Scanner.strippingExemptBlocks(source)
        XCTAssertEqual(blocks, 1)
        XCTAssertFalse(scannable.contains("她先"))
        XCTAssertTrue(scannable.contains("让他"), "标记关闭后应当恢复扫描，否则半张文件会失明")
    }
}
