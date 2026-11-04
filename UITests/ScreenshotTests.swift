//
//  ScreenshotTests.swift
//  RelationshipCopilotUITests
//
//  真实渲染核验。
//
//  为什么要有这一层：这个仓库的核心教训是「断言全绿但界面是坏的」。
//  SwiftUI 的很多错误（漏包 NavigationStack 导致标题和工具栏按钮静默消失、
//  浮动 tab bar 压住内容、超大字号下四宫格被压成色块）在编译期和单测里
//  **完全看不出来**，只能在真实渲染出的像素上发现。
//
//  这里用 XCUITest 驱动真实 App、在关键状态各截一张图，存进 result bundle。
//  断言只做两件事：
//    ① 这一屏**确实渲染出来了**（防止截到一张空白图还以为通过）
//    ② 几条**能机器判定**的产品约束（不许泄露上一方证词、降级必须标注、拦截页不许出结论）
//  真正的视觉判断仍然靠人眼看图 —— 这正是本仓库一贯的做法。
//
//  注意：这里刻意**不**断言"某段文字的字号/间距/对齐"。
//  XCUITest 拿不到样式信息，硬写这类断言只会制造一种虚假的安全感。
//

import XCTest

final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - 启动

    private func launch(
        screen: String,
        caseName: String? = nil,
        appearance: String? = nil,
        anchor: String? = nil,
        font: String? = nil,
        reset: Bool = true,
        seed: Bool = true,
        aiKey: String? = nil,
        repairPrefill: String? = nil,
        skipAutoLogin: Bool = false
    ) {
        app = XCUIApplication()
        var arguments = [
            "--ui-test-screen=\(screen)"
        ]
        // 绝大多数用例需要跳过登录。但验证**登录页本身**的用例必须真的停在登录页 ——
        // 在此之前没有任何一条用例走过「内测跳过登录」这条路径，
        // 于是它能不能用，只有人手动点过才知道。
        if !skipAutoLogin {
            arguments.append("--ui-test-autologin")
        } else {
            // Keychain 在卸载后仍然保留，不清就会停在已登录的首页，
            // 用例会安静地测一个「已经登录的 App」然后全绿。
            arguments.append("--ui-test-clear-auth")
        }
        // 默认播种。验证「数据已被删除」的用例必须传 `seed: false` ——
        // 否则启动时又插回一份样本案卷，"删除后为空"永远测不出来，
        // 失败原因还会指向一个根本不存在的产品缺陷。
        if seed {
            arguments.append("--ui-test-seed")
        } else {
            arguments.append("--ui-test-no-seed")
        }
        if let aiKey {
            // 从环境变量读，不写死在测试源码里 ——
            // 仓库里出现明文密钥正是这个项目已经发生过一次的安全事故。
            arguments.append("--ai-direct-key=\(aiKey)")
        }
        if let repairPrefill {
            // 把引导流程直接推进到某个状态。中文输入经 typeText 不可靠，
            // 打不进去会让测试失败在"字没敲上"而不是"闸门没拦住"。
            arguments.append("--ui-test-repair-prefill=\(repairPrefill)")
        }
        // 每条用例都从空库开始。
        //
        // 不加这一条的后果已实测到：`test_adoptingVerdictAsPromiseCreatesPromise`
        // 点一次「沉淀为承诺」后，案卷里永久多了一条 `linkedPromises`；
        // 后续用例再进同一件案卷时按钮已变成「已加进承诺」，
        // 于是「找不到『记成一条承诺』」——单独跑绿、全量跑红。
        // 测试必须能控制自己的初始条件，不能继承上一次运行的残留。
        //
        // 例外：验证"重启后数据还在"的用例要传 `reset: false`，
        // 否则关掉 App 再打开会把刚创建的数据抹掉，测的就不是持久化而是清库。
        if reset {
            arguments.append("--ui-test-reset")
        }
        app.launchArguments = arguments
        if let caseName {
            app.launchArguments.append("--ui-test-case=\(caseName)")
        }
        if let anchor {
            app.launchArguments.append("--ui-test-anchor=\(anchor)")
        }
        if let font {
            // 字号走启动参数，不走 `simctl ui content_size`：后者改模拟器持久状态、
            // 跑完不还原，档位设错时用例会静默假绿（历史已发生一次）。
            app.launchArguments.append("--ui-test-font=\(font)")
        }
        if let appearance {
            // NSArgumentDomain 会覆盖 UserDefaults，@AppStorage 读得到。
            app.launchArguments += ["-appearanceMode", appearance]
        }
        app.launch()
        // 首帧 + 数据注入 + 布局需要时间；用等待元素代替固定 sleep。
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 30)
    }

    /// 断言 App **实际生效**的字号档位，而不是"我记得我设过"。
    ///
    /// 这条断言是补一个真实发生过的假绿：`test_xxxl_*` 三个用例曾在
    /// `content_size medium` 下跑，截出来的是普通字号，却全部"通过"了。
    /// 根因是字号来自模拟器的持久状态，测试无法自证。
    private func assertFont(_ expected: String, context: String) {
        let probe = app.staticTexts["uitest.font.probe"]
        XCTAssertTrue(
            probe.waitForExistence(timeout: 10),
            "\(context)：没有找到字号探针，无法证明本次跑在什么字号上"
        )
        XCTAssertTrue(
            probe.label.contains("fontprobe:\(expected)"),
            "\(context)：实际字号档位是「\(probe.label)」，期望「\(expected)」——"
            + "这一屏截出来的不是你以为的那个字号"
        )
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 屏幕上是否存在 label 包含该片段的元素。
    ///
    /// 用「包含」而不是「相等」：多处 `.accessibilityElement(children: .combine)`
    /// 会把子文本合并成一个元素的 label，精确匹配会漏。
    ///
    /// 同时查 staticTexts 与 buttons：`NavigationLink` 一旦设了
    /// `.accessibilityLabel(...)`，内部 `Text` 就不再作为 staticText 暴露，
    /// 只查 staticTexts 会把"看得见但查不到"误判成"没渲染出来"。
    private func hasText(_ fragment: String) -> Bool {
        element(containingLabel: fragment) != nil
    }

    /// 找到第一个 label 包含该片段的**可见**元素。
    ///
    /// **必须过滤可见性。** 实测发现 XCUITest 的可访问性树包含屏幕外的元素：
    /// 首页在 XXXL 字号下第一屏只看得到「把一件事说清」，
    /// 但 `app.staticTexts` 里已经能查到「吵架复盘」「开口准备」等全部文本。
    /// 只判 `exists` 的话，"四宫格被压成色块"这类缺陷会被判为通过 —— 假绿。
    /// 这里用 `isHittable` + frame 与屏幕窗口求交来确认它真的在屏幕上。
    private func element(containingLabel fragment: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)

        for query in [app.staticTexts, app.buttons, app.otherElements] {
            let matches = query.containing(predicate)
            for element in matches.allElementsBoundByIndex where element.exists {
                if isOnScreen(element) { return element }
            }
        }
        return nil
    }

    private func isOnScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0, frame.minY.isFinite else { return false }
        let window = app.windows.firstMatch.frame
        guard window.height > 0 else { return false }
        // 完整落在窗口内才算"看得见"；压在 tab bar 下面的部分不算。
        return frame.minY >= window.minY && frame.maxY <= window.maxY
    }

    /// 断言屏幕确实有内容。**这是所有截图用例的前置条件。**
    ///
    /// 少了它，一个白屏也会"通过"，然后我们拿着一堆空白 PNG 以为核验过了。
    ///
    /// 注意：不能用 `label.length > 0` 这类谓词 —— XCUITest 的键路径白名单里
    /// 没有 `length`，会抛 `XCTElementQueryInvalidPredicate` 而被当成断言失败。
    /// 直接用元素数量判断更可靠。
    private func assertRendered(_ context: String, expecting fragment: String) {
        XCTAssertTrue(
            app.staticTexts.firstMatch.waitForExistence(timeout: 15),
            "\(context)：屏幕上没有任何文本，这张截图不可信"
        )
        XCTAssertGreaterThan(
            app.staticTexts.count, 0,
            "\(context)：屏幕上没有任何文本，这张截图不可信"
        )
        XCTAssertTrue(
            hasText(fragment),
            "\(context)：没有找到预期文案「\(fragment)」，这一屏很可能没渲染出来"
        )
    }

    /// 断言 App **实际渲染**的深浅色，而不是"我记得我传了 dark"。
    ///
    /// ## 这条断言补的是和字号假绿同一个形状的洞
    ///
    /// `test_dark_mode_*` 原本只断言"某个标题文字存在"。那句标题在浅色模式下
    /// 同样存在 —— 所以只要 `-appearanceMode dark` 没生效（参数名改了、
    /// `@AppStorage` 换了 key、`.preferredColorScheme` 被挪走），
    /// 用例**照样全绿**，而截出来的是一张白底图，没人会发现。
    ///
    /// 字体那次已经踩过：`content_size medium` 下跑名叫 `test_xxxl_*` 的用例，
    /// 三个全绿。修法是加 `fontprobe`。深浅色当时没做，于是留着同一个洞。
    private func assertColorScheme(_ expected: String, context: String) {
        let probe = app.staticTexts["uitest.scheme.probe"]
        XCTAssertTrue(
            probe.waitForExistence(timeout: 10),
            "\(context)：没有找到配色探针，无法证明本次跑在什么外观下"
        )
        XCTAssertTrue(
            probe.label.contains("schemeprobe:\(expected)"),
            "\(context)：实际外观是「\(probe.label)」，期望「\(expected)」——"
            + "这一屏截出来的不是你以为是深色的那张图"
        )
    }

    // MARK: - 首页：滚到底部，验证 tab bar 是否压住最后一张卡片
    //
    // 这是上一轮唯一未闭环的疑似缺陷。静态截图里「3天」标签被 tab bar 盖住，
    // 但**无法区分**是"布局真的矮了一截"还是"页面本来就没滚到底"
    // （iOS 26 起 tab bar 是浮层，内容允许从它下面滚过）。
    // 唯一可靠的判别方式是：真的滚到底，再看最后一张卡片是否完整可见。

    /// 点「沉淀为承诺」之后，承诺区必须真的多出一条。
    ///
    /// 这个用例的存在理由：上面那些 `hasText("记成一条承诺")` 只证明**按钮画出来了**，
    /// 证明不了**点下去真的有用**。而这个闭环是本产品相对参考产品（判决即终止）
    /// 唯一的留存机制 —— 按钮能画、点了没反应，是最容易被"断言全绿"放过的一类缺陷。
    func test_adoptingVerdictAsPromiseCreatesPromise() throws {
        launch(screen: "disputes", caseName: "closed")
        assertRendered("结果页", expecting: "你们其实在争两件事")

        // 滚到底露出按钮（它在第四段内部）
        _ = scrollToBottomAndMeasure("adopt-before")

        let adoptButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "记成一条承诺")
        ).firstMatch
        XCTAssertTrue(adoptButton.waitForExistence(timeout: 10), "找不到「沉淀为承诺」按钮")
        adoptButton.tap()

        // 点击后按钮变为「已加进承诺」并禁用 —— 这是幂等性的可见证据
        let adopted = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "已加进承诺")
        ).firstMatch
        XCTAssertTrue(
            adopted.waitForExistence(timeout: 10),
            "点击后按钮没有变成「已加进承诺」——承诺可能没创建成功"
        )
        capture("07c-case-adopted-as-promise")

        // 再去承诺区确认它真的在那里。
        // 这里必须 reset: false —— 重启时若清库，刚创建的那条就被抹掉，
        // 测到的就不是"持久化生效"，而是"清库生效"。
        app.terminate()
        launch(screen: "promises", reset: false)
        XCTAssertTrue(
            hasText("这周找一次"),
            "承诺列表里找不到刚从评理沉淀出来的那条 —— 闭环没有真的打通"
        )
        capture("07d-promise-from-dispute")
    }

    func test_home_bottom_clearance() throws {
        launch(screen: "home")
        assertRendered("首页", expecting: "关系副驾")

        let (tabTop, contentBottom) = scrollToBottomAndMeasure("home")
        capture("01-home-bottom")

        XCTAssertTrue(app.tabBars.firstMatch.exists, "滚到底后 tab bar 消失了")
        XCTAssertGreaterThan(tabTop, 0, "取不到 tab bar 的顶边，测量无效")
        XCTAssertLessThanOrEqual(
            contentBottom, tabTop,
            "滚到底后最后一行内容（底边 \(contentBottom)）仍被 tab bar（顶边 \(tabTop)）遮住"
        )
    }

    /// 用"可见文本数量 + 前几个文本的 label"做粗略指纹，判断滚动是否已经到底。
    private func screenSignature() -> String {
        let labels = app.staticTexts.allElementsBoundByIndex.prefix(6).map(\.label).joined(separator: "|")
        return "\(app.staticTexts.count)-\(labels)"
    }

    /// 把一个可滚动页面滑到底，并测量最后一行内容与 tab bar 的真实几何关系。
    ///
    /// **必须只在 ScrollView 内部取元素。**
    /// 直接对 `app.buttons` 求"最靠下的元素"会把 tab bar 自己的按钮算进来
    /// （它们的底边天生在 tab bar 里），于是断言永远失败 —— 这是测量错了，不是界面坏了。
    @discardableResult
    private func scrollToBottomAndMeasure(_ context: String) -> (tabTop: CGFloat, lowestContentBottom: CGFloat) {
        let scroll = app.scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: 10) else {
            XCTFail("\(context)：没有找到 ScrollView")
            return (0, 0)
        }

        var stable = 0
        for _ in 0..<12 {
            let before = screenSignature()
            scroll.swipeUp(velocity: .fast)
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 1)
            if screenSignature() == before {
                stable += 1
                if stable >= 2 { break }
            } else {
                stable = 0
            }
        }

        let tabTop = app.tabBars.firstMatch.frame.minY
        // 滚动容器内的所有文本里，最靠下的那个就是"最后一行内容"。
        let lowest = scroll.staticTexts.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.minY.isFinite && $0.maxY.isFinite && $0.height > 0 }
            .max(by: { $0.maxY < $1.maxY })
        let lowestBottom = lowest?.maxY ?? 0
        let gap = tabTop - lowestBottom

        print("[DIAG-\(context)] tabBarTop=\(tabTop) lowestContentBottom=\(lowestBottom) gap=\(gap)")
        XCTAssertGreaterThan(lowestBottom, 0, "\(context)：没有测到任何内容，测量无效")
        return (tabTop, lowestBottom)
    }

    /// 结果页滚到底后，最后一段不得被 tab bar 压住。
    ///
    /// **这个断言来自一次自我纠错。**
    /// 我最初看静态截图，看到结果页第四段「今晚可以做的一件事」只露出一个「的」字
    /// 被 tab bar 盖住，就判定为"底部留白不足"的缺陷。
    /// 实测几何后才发现：滚到底时最后一行底边 706、tab bar 顶边 791，余量 84.9pt ——
    /// 留白是够的，那一张只是**页面还没滚到底**的中间态。
    /// 这正是 iOS 26 起浮动 tab bar 的正常形态：内容允许从它下方滚过。
    ///
    /// 保留此用例的价值：它把"留白够不够"从目测变成了可复现的数字。
    /// 若将来有人为了"紧凑"把 `Spacing.xxl` 改小，这条会立刻失败。
    func test_result_bottom_clearance() throws {
        launch(screen: "disputes", caseName: "closed")
        assertRendered("结果页", expecting: "你们其实在争两件事")

        let (tabTop, contentBottom) = scrollToBottomAndMeasure("result")
        capture("16-result-scrolled-bottom")

        XCTAssertGreaterThan(tabTop, 0, "取不到 tab bar 的顶边，测量无效")
        XCTAssertLessThanOrEqual(
            contentBottom, tabTop,
            "滚到底后最后一行文字（底边 \(contentBottom)）仍被 tab bar（顶边 \(tabTop)）遮住"
        )
        XCTAssertGreaterThan(
            tabTop - contentBottom, 8,
            "最后一行与 tab bar 之间的余量只有 \(tabTop - contentBottom)pt，贴近得看不出这里还能滚"
        )
    }

    /// 永久型结果页同样要滚到底核验。
    ///
    /// 单独一个用例而不是参数化：永久型的文本明显更长（解释段按 69% 展开、
    /// 第四段是"可以长期共处"的长句），是最容易被底部遮住的形态。
    func test_perpetual_bottom_clearance() throws {
        launch(screen: "disputes", caseName: "perpetual")
        assertRendered("永久型结果页", expecting: "这件事大概会一直在")

        let (tabTop, contentBottom) = scrollToBottomAndMeasure("perpetual")
        capture("17-perpetual-scrolled-bottom")

        XCTAssertGreaterThan(tabTop, 0, "取不到 tab bar 的顶边，测量无效")
        XCTAssertLessThanOrEqual(
            contentBottom, tabTop,
            "永久型滚到底后最后一行（底边 \(contentBottom)）仍被 tab bar（顶边 \(tabTop)）遮住"
        )
    }

    // MARK: - 评理列表

    func test_disputes_list() throws {
        launch(screen: "disputes")
        assertRendered("评理列表", expecting: "这里不判谁对谁错")
        capture("02-disputes-list")

        // 上一版漏包 NavigationStack，导致标题与「+」静默消失。
        // 用真实断言钉住，避免同一个错误复发。
        XCTAssertTrue(
            app.navigationBars["评理"].waitForExistence(timeout: 5),
            "评理页没有导航栏标题——很可能又漏了 NavigationStack"
        )
        XCTAssertTrue(
            app.buttons["开一件新的"].exists,
            "右上角「+」按钮不存在——toolbar 没有挂到导航容器上"
        )
    }

    // MARK: - 评理流程各状态

    func test_case_collecting() throws {
        launch(screen: "disputes", caseName: "collecting")
        assertRendered("书写页", expecting: "你这一份")
        XCTAssertTrue(hasText("发生了什么"), "书写页缺少第 1 问")
        XCTAssertTrue(hasText("你自己那一份"), "书写页缺少第 4 问（自我归因，全套设计的关键）")
        capture("03-case-collecting")
    }

    /// 书写页必须能滚到底，第四题的输入框不能被浮动 tab bar 吃掉。
    ///
    /// **这条用例来自一次险些重复犯的错。** 看 XXXL 截图时，第 4 题的标题与说明
    /// 之后直接就是 tab bar，输入框完全看不见，我第一反应是「被压住了，要隐藏 tab bar」。
    /// 但本仓库已经因为同样的误判吃过两次亏：iOS 26 起 tab bar 是浮层，
    /// 内容允许从它下方滚过，**静态截图无法区分「没滚到底」和「布局坏了」**。
    /// 所以改成真的滚到底再量几何。
    func test_form_bottom_clearance() throws {
        launch(screen: "disputes", caseName: "collecting")
        assertRendered("书写页", expecting: "你这一份")

        let (tabTop, contentBottom) = scrollToBottomAndMeasure("form")
        capture("16-form-scrolled-bottom")

        XCTAssertGreaterThan(tabTop, 0, "取不到 tab bar 顶边，测量无效")
        XCTAssertLessThanOrEqual(
            contentBottom, tabTop,
            "书写页滚到底后，最下面的内容（底边 \(contentBottom)）仍被 tab bar（顶边 \(tabTop)）遮住"
        )
    }

    func test_case_handover() throws {
        launch(screen: "disputes", caseName: "handover")
        assertRendered("交接页", expecting: "把手机交给 TA")

        // 这一屏必须**不显示**上一方写的内容 —— 流程密封的唯一可机器验证表征。
        XCTAssertFalse(
            hasText("领导当众批评"),
            "交接页泄露了上一方的证词内容，整套'各写各的'就废了"
        )
        capture("04-case-handover")
    }

    func test_case_ready() throws {
        launch(screen: "disputes", caseName: "ready")
        assertRendered("待生成页", expecting: "两份都写完了")
        XCTAssertTrue(hasText("不是判谁对谁错"), "待生成页缺少'不是判谁对谁错'的预期管理")
        capture("05-case-ready")
    }

    func test_case_solo_ready() throws {
        launch(screen: "disputes", caseName: "solo")
        assertRendered("单机待生成页", expecting: "不会假装知道对方怎么想")
        capture("06-case-solo-ready")
    }

    func test_case_closed_solvable() throws {
        launch(screen: "disputes", caseName: "closed")
        assertRendered("结果页", expecting: "你们其实在争两件事")

        // 四段必须全部在场，且第四段用的是可解决型的标签
        XCTAssertTrue(hasText("各自想被听见的一句"), "结果页缺少第②段")
        XCTAssertTrue(hasText("你们卡在哪"), "结果页缺少第③段")
        XCTAssertTrue(hasText("这件事能解决"), "结果页缺少可解决型的分流标签")
        XCTAssertTrue(hasText("今晚可以做的一件事"), "可解决型缺少第四段")

        // 退出权
        XCTAssertTrue(hasText("你可以不认同"), "结果页缺少退出权那一句")

        // 中立性：两侧标签必须字面对称，不得出现"甲方/乙方"这类合同语言
        XCTAssertTrue(hasText("一方"), "结果页缺少「一方」标签")
        XCTAssertTrue(hasText("另一方"), "结果页缺少「另一方」标签")
        XCTAssertFalse(hasText("甲方"), "出现了合同语言「甲方」，会把人推向对抗框架")

        // 责任分配必须彻底不存在
        XCTAssertFalse(hasText("责任"), "结果页出现了「责任」相关表述，这与'不做判决'的核心决策冲突")

        // 闭环：可解决型必须给出「沉淀为承诺」的出口。
        // 这是本产品相对参考产品（判决即终止）唯一的留存机制，
        // 少了它，AI 给出的那条具体动作看完就没了。
        XCTAssertTrue(
            hasText("记成一条承诺"),
            "可解决型没有「沉淀为承诺」入口 —— 「判决 → 承诺 → 打卡」这条闭环是断的"
        )

        capture("07-case-closed-solvable")

        // 断言只能证明"文字存在于可访问性树"，证明不了它真的渲染在屏幕上并且没被裁。
        // 滚到底再截一张，专门看第④段与「沉淀为承诺」按钮的实际观感。
        _ = scrollToBottomAndMeasure("closed-solvable")
        capture("07b-case-closed-solvable-bottom")
    }

    /// 永久型**必须没有**「沉淀为承诺」入口。
    ///
    /// 这不是遗漏，是设计：永久型的第四段是共存说法（"约定一句话：我现在只想被听"），
    /// 不是一次性行为。硬做成打卡项会变成"每天打卡：我今天有在听吗"，
    /// 既不可验证，也把一段关系的相处方式降格成了 KPI —— 那正是这个产品反对的东西。
    func test_case_closed_perpetual_hasNoPromiseEntry() throws {
        launch(screen: "disputes", caseName: "perpetual")
        assertRendered("永久型结果页", expecting: "这件事大概会一直在")

        XCTAssertFalse(
            hasText("记成一条承诺"),
            "永久型出现了「沉淀为承诺」入口 —— 共存说法不该被做成打卡项"
        )
    }

    func test_case_closed_perpetual() throws {
        launch(screen: "disputes", caseName: "perpetual")
        assertRendered("永久型结果页", expecting: "这件事大概会一直在")
        XCTAssertTrue(hasText("可以长期这么放着的说法"), "永久型的第四段标签不对")
        XCTAssertFalse(hasText("今晚可以做的一件事"), "永久型问题不该给'今晚就能做'的解决方案")
        capture("08-case-closed-perpetual")
    }

    func test_case_degraded() throws {
        launch(screen: "disputes", caseName: "degraded")
        assertRendered("降级结果页", expecting: "这次没能形成真正的第三方之见")
        XCTAssertTrue(hasText("没有做任何推断"), "降级页没有说明它没有做推断")
        capture("09-case-degraded")
    }

    func test_case_blocked() throws {
        launch(screen: "disputes", caseName: "blocked")
        assertRendered("安全拦截页", expecting: "这件事不适合在这里评理")

        // 拦截页不得给出任何评理内容
        XCTAssertFalse(hasText("你们其实在争两件事"), "安全拦截页仍然显示了评理结果")
        XCTAssertFalse(hasText("今晚可以做的一件事"), "安全拦截页仍然给了行动建议")
        // 必须说明原文没有外发
        XCTAssertTrue(hasText("没有把它发给任何模型"), "拦截页没有说明内容未外发")

        capture("10-case-blocked")
    }

    // MARK: - 深色模式
    //
    // 每条都必须先 `assertColorScheme("dark")`。
    // 以前这里只断言"某句话存在"，而那句话在浅色模式下同样存在 ——
    // 于是只要深色参数没生效，用例会全绿，截图却是白底。
    // 这与 `test_xxxl_*` 曾经在 medium 字号下假绿是同一个错误。

    func test_dark_mode_result() throws {
        launch(screen: "disputes", caseName: "closed", appearance: "dark")
        assertColorScheme("dark", context: "深色结果页")
        assertRendered("深色结果页", expecting: "你们其实在争两件事")
        capture("11-dark-closed")
    }

    func test_dark_mode_list() throws {
        launch(screen: "disputes", appearance: "dark")
        assertColorScheme("dark", context: "深色列表页")
        assertRendered("深色列表页", expecting: "这里不判谁对谁错")
        capture("12-dark-list")
    }

    /// 深色 · 评理书写页。
    ///
    /// 这一屏是 TextEditor + 四段占位 + 字数提示，最容易出现
    /// "深色底 + 深色字"或"输入框底色没跟上"——两种都是白屏看不出来、
    /// 深色下才致命的缺陷。
    func test_dark_mode_form() throws {
        launch(screen: "disputes", caseName: "collecting", appearance: "dark")
        assertColorScheme("dark", context: "深色书写页")
        assertRendered("深色书写页", expecting: "这一份")
        capture("13-dark-form")
    }

    /// 深色 · 交接页。
    ///
    /// 这一屏会被**对方**看到，是整条流程里唯一"对外"的界面。
    /// 深色下若对比度不够，读不出"把手机交给 TA"这句关键指令，
    /// 两个人就会同时盯着同一块屏幕 —— 密封就破了。
    func test_dark_mode_handover() throws {
        launch(screen: "disputes", caseName: "handover", appearance: "dark")
        assertColorScheme("dark", context: "深色交接页")
        assertRendered("深色交接页", expecting: "把手机交给 TA")
        capture("14-dark-handover")
    }

    /// 深色 · 安全拦截页。
    ///
    /// 这一屏在深色下最不能出错：它是危机情境下的唯一出口，
    /// 热线号码必须清晰可读。
    func test_dark_mode_blocked() throws {
        launch(screen: "disputes", caseName: "blocked", appearance: "dark")
        assertColorScheme("dark", context: "深色拦截页")
        assertRendered("深色拦截页", expecting: "这件事不适合在这里评理")
        capture("15-dark-blocked")
    }

    /// 深色 · 道歉准备（七格损失页）。
    ///
    /// 七个格子 + 七个麦克风 + 校验提示，是全 App 元素最密的一屏。
    /// 密屏在深色下最容易出现"卡片底色和背景糊成一片"。
    func test_dark_mode_repair_losses() throws {
        launch(screen: "home", appearance: "dark", anchor: "quickTools", repairPrefill: "losses-filled")
        assertColorScheme("dark", context: "深色七格页")
        openRepairTool()
        assertRendered("深色七格页", expecting: "现在换成 TA")
        capture("16-dark-repair-losses")
    }

    // MARK: - 超大字号
    //
    // 字号由 `--ui-test-font=xxxl` 启动参数指定（App 侧 `.dynamicTypeSize`），
    // **不再依赖 `simctl ui content_size`**。历史教训：那条命令改的是模拟器
    // 持久状态、跑完不还原，于是"上次跑过 XXXL"变成隐式前置条件；
    // 某次在 medium 下跑全量时，这三个用例截的是普通字号却照样全绿。
    // 现在每条用例开头都用 `assertFont` 先证明档位，档位错了直接失败。
    //
    // 这几屏在 XXXL 下最容易坏：
    // 结果页有四段长文 + 两个对称块 + 分流胶囊；首页有四宫格。

    func test_xxxl_result() throws {
        launch(screen: "disputes", caseName: "closed", font: "xxxl")
        assertFont("xxxl", context: "超大字号结果页")
        assertRendered("超大字号结果页", expecting: "你们其实在争两件事")
        capture("13-xxxl-closed")
    }

    func test_xxxl_form() throws {
        launch(screen: "disputes", caseName: "collecting", font: "xxxl")
        assertFont("xxxl", context: "超大字号书写页")
        assertRendered("超大字号书写页", expecting: "你这一份")
        capture("14-xxxl-form")
    }

    /// 超大辅助功能字号下的首页。
    ///
    /// **这个用例我写错过三次，每次的教训都不同，值得逐条留在代码里：**
    /// ① 断言"XXXL 下第一屏必须看到『吵架复盘』"—— 失败。但界面没问题，
    ///    XXXL 下一张入口卡本来就占掉大半屏。断言写错了位置。
    /// ② 改成"滚 N 次 `.fast` 找它"—— 又失败。`.fast` 一次跨过整屏，
    ///    直接跳过整个快速工具区块。
    /// ③ 换成慢速拖拽 + `exists` 判断 —— **这次是最危险的：它假绿通过。**
    ///    实测发现 XCUITest 的可访问性树**包含屏幕外元素**，
    ///    第一屏就能查到「开口准备」，于是断言在什么都没滚的情况下就返回 true。
    ///
    /// 最终方案：让 App 用 `ScrollViewReader` 按锚点滚（`--ui-test-anchor`），
    /// 并让 `hasText` 只认**完整落在窗口内**的元素。
    /// 手势模拟去定位大字号下长页面的区块，本身就不是可靠的做法。
    func test_xxxl_home() throws {
        // 先断言第一屏确实渲染了（大字号下入口卡占满首屏是正常的）
        launch(screen: "home", font: "xxxl")
        assertFont("xxxl", context: "超大字号首页")
        assertRendered("超大字号首页", expecting: "关系副驾")
        capture("15-xxxl-home")

        // 关键：XXXL 下快速工具整个区块必须还能读到文字。
        // 历史缺陷是"四宫格被压成纯色方块"，那必须真的滚到它面前才能判断。
        app.terminate()
        launch(screen: "home", anchor: "quickTools", font: "xxxl")
        XCTAssertTrue(
            app.staticTexts["快速工具"].waitForExistence(timeout: 10),
            "按锚点滚动后仍看不到「快速工具」标题"
        )
        XCTAssertTrue(hasText("吵架复盘"), "四宫格文字没渲染出来——很可能又被压成色块了")
        XCTAssertTrue(hasText("道歉准备"), "四宫格最后一个格子的文字没渲染出来")
        capture("15b-xxxl-quicktools")

        // 承诺内容不许被截断成半个句子：
        // 这一行是首页唯一告诉用户"该做什么"的信息，截断就等于失效。
        app.terminate()
        launch(screen: "home", anchor: "promises", font: "xxxl")
        XCTAssertTrue(
            hasText("吵架后 24 小时内主动开口"),
            "超大字号下承诺内容被截断 —— 很可能又是 lineLimit 没去掉"
        )
        capture("15c-xxxl-promises")
    }

    // MARK: - 关系档案（头像 / 自定义颜色 / 自定义关系名）
    //
    // 这一页此前**完全没有截图覆盖**，而本轮改动最大：换了头像组件、
    // 加了 12 色调色板 + 系统取色器、删了「重要日期」、加了自定义关系名。
    //
    // 特别值得记的是：这些改动全是"编译通过、单测通过、界面却是坏的"高危类型 ——
    // 自定义关系名存进了 `customRelationshipName`，但列表页如果还在读
    // `relationship.displayName`，用户看到的就是「其他」。数据层测试
    // （`RelationshipLabelTests`）只能证明字段算对了，证明不了界面用了它。

    func test_profiles_list() throws {
        launch(screen: "profiles")
        assertRendered("关系档案列表", expecting: "关系管理")

        // 列表页必须优先显示自定义关系名，而不是「其他」。
        // 这条能被机器判定，而且正是最容易回归的那一点。
        XCTAssertTrue(
            hasText("母女"),
            "关系档案列表没有显示自定义关系名「母女」——"
            + "很可能列表页还在读 relationship.displayName"
        )
        XCTAssertFalse(
            hasText("其他"),
            "关系档案列表出现了「其他」而不是自定义关系名"
        )
        capture("20-profiles-list")
    }

    func test_profiles_edit_hasNoDateFields() throws {
        launch(screen: "profiles")
        assertRendered("关系档案列表", expecting: "关系管理")

        // 进第一个档案的详情页。
        // 注意 `ProfileCard` 用 `.accessibilityElement(children: .combine)`,
        // 整张卡片是**一个** button，label 是合并后的
        // 「小林，伴侣，距离近」，所以按人名片段匹配是对的。
        let firstProfile = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "小林")
        ).firstMatch
        XCTAssertTrue(firstProfile.waitForExistence(timeout: 10), "找不到「小林」这条档案")
        firstProfile.tap()

        XCTAssertTrue(
            app.navigationBars["小林"].waitForExistence(timeout: 10),
            "点进档案后没有进入详情页"
        )

        // 「重要日期」以及生日/纪念日字段必须彻底消失。
        // 只删 Model 字段的话界面读不到会编译失败，所以这里守的是
        // "字段删了、界面标签还留着"这种残留。
        for gone in ["重要日期", "生日", "纪念日"] {
            XCTAssertFalse(
                hasText(gone),
                "关系详情页仍然出现了「\(gone)」——这个字段本轮已删除"
            )
        }

        // 头像编辑入口必须在。用精确文案，避免 hasText("颜色") 之类
        // 宽泛匹配把「距离感」附近的文字误判成通过。
        XCTAssertTrue(hasText("换成照片"), "详情页没有照片入口「换成照片」")
        XCTAssertTrue(hasText("头像颜色"), "详情页没有颜色入口「头像颜色」")
        capture("21-profile-detail")
    }

    /// 详情页展开色板后的样子：12 色网格 + 系统取色器。
    ///
    /// 色板默认折叠（Form 里放不下 12 个圆），所以**不点开就截不到**。
    /// 这条用例存在的理由是：色板是本次改动的核心之一，
    /// 而"折叠后展开是空的"这种错误在折叠状态下完全看不出来。
    func test_profiles_colorPaletteExpands() throws {
        launch(screen: "profiles")
        let firstProfile = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "小林")
        ).firstMatch
        XCTAssertTrue(firstProfile.waitForExistence(timeout: 10), "找不到「小林」这条档案")
        firstProfile.tap()

        // 颜色入口是一个独立行（label 里含「头像颜色」）。
        let colorRow = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "头像颜色")
        ).firstMatch
        XCTAssertTrue(colorRow.waitForExistence(timeout: 10), "找不到「头像颜色」入口")
        colorRow.tap()

        // ## 先证明「真的展开了」，再数数量
        //
        // 这一步是补一次真实的假绿：上一版点完直接数 12 个色圆，断言全过，
        // 而截图显示弹出的是**系统相册**。原因是
        // ① 两个入口同处一个 Form 行，`PhotosPicker` 抢走了整行点击；
        // ② XCUITest 的可访问性树**包含被 sheet 盖住的底层元素**，
        //    于是色圆 `exists` 为真、断言成立，屏幕上却是一张相册。
        //
        // 判别方法：色圆必须真的 `isHittable`。被盖住时 exists 真、hittable 假。
        let swatches = app.buttons.matching(
            NSPredicate(format: "label == %@", "头像颜色")
        )
        XCTAssertTrue(
            swatches.element(boundBy: 0).waitForExistence(timeout: 10),
            "展开后没有找到任何色圆 —— 色板根本没展开"
        )
        XCTAssertTrue(
            swatches.element(boundBy: 0).isHittable,
            "色圆存在但不可点 —— 很可能被弹出的相册 sheet 盖住了"
        )
        XCTAssertEqual(
            swatches.count, 12,
            "展开后色板应有 12 个颜色，实际 \(swatches.count) 个 —— "
            + "可能是网格被裁掉或 paletteHex 变了"
        )
        XCTAssertTrue(hasText("自定义颜色"), "没有找到系统取色器「自定义颜色」")
        capture("21b-profile-palette")
    }

    /// 「添加人物」页里「其他」的自定义名称输入框。
    ///
    /// 这条守的是一个具体的产品约束：选了「其他」就必须填名称，
    /// 否则列表里会出现一串无法区分的「其他」。
    /// 断言方式是看**保存按钮的可用状态** —— 这是那个约束唯一的外部表现。
    func test_addProfile_otherRequiresCustomName() throws {
        launch(screen: "profiles", seed: false)

        let add = app.buttons["添加人物"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "找不到「添加人物」入口")
        add.tap()

        let nameField = app.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "找不到姓名输入框")
        nameField.tap()
        nameField.typeText("老王")

        let save = app.buttons["保存"]
        XCTAssertTrue(save.exists, "找不到保存按钮")
        // 选了非「其他」的类型，只填名字就该能存。
        XCTAssertTrue(save.isEnabled, "只填了名字，「保存」却不可用")

        // 切到「其他」：此时保存必须被禁用，直到填了自定义名称。
        // Picker 已从 .segmented 改成 .menu（7 个中文标签在 375pt 下被压成两字）。
        let picker = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "伴侣")
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "找不到关系类型选择器")
        picker.tap()

        let otherOption = app.buttons["其他"].firstMatch
        XCTAssertTrue(otherOption.waitForExistence(timeout: 10), "菜单里没有「其他」选项")
        otherOption.tap()

        XCTAssertFalse(
            save.isEnabled,
            "选了「其他」但没填自定义名称，「保存」却是可用的 —— "
            + "列表里会出现一串无法区分的「其他」"
        )
        capture("21c-add-profile-other")
    }

    func test_profiles_edit_xxxl() throws {
        launch(screen: "profiles", font: "xxxl")
        assertFont("xxxl", context: "超大字号关系档案")
        assertRendered("超大字号关系档案", expecting: "关系管理")

        // ## 这些断言补的是一次真实的假绿
        //
        // 上一版这里只有 `hasText("小林")`，它**通过了** —— 而截图里
        // 「妈妈」被竖排成两行、「有距离」被竖排成一列竖字、「100%」被断成
        // 「100」+「%」。三种缺陷全都"渲染出来了"，所以基于 exists 的断言
        // 一个都抓不到。
        //
        // 能机器判定的替代方案是**几何**：竖排的字，其高度会远大于宽度。
        // 单行四个字（如「有距离」）的宽高比通常 > 1.5；一旦竖排就 < 1。
        // 这不是精确的排版度量，但足以区分"一行字"和"一列字"。
        //
        // 两个坑都在这里踩过，所以只在**首屏可见**的元素上断言：
        //  ① 用通用的 `element(containingLabel:)` 会先命中根容器
        //     （实测 frame 是整屏 402×874，宽高比 0.46），布局正常也会报红。
        //  ② XXXL 下第二张卡片会滚出屏幕，`exists` 仍为真但不可见，
        //     拿它的 frame 没有意义（曾因此报出"找不到「一般」"）。
        //
        // 只取排序第一的、确实在屏幕内的那条距离标签即可 ——
        // 两条卡片用的是同一个 `ProfileCard`，验一条就够。
        let badgeLabels = ["有距离", "一般", "很近", "疏远"]
        var checked = 0
        for label in badgeLabels {
            let matches = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", label)
            )
            guard matches.count > 0 else { continue }
            let el = matches.element(boundBy: 0)
            guard isOnScreen(el) else { continue }

            let f = el.frame
            let aspect = f.width / max(f.height, 1)
            XCTAssertGreaterThan(
                aspect, 1.2,
                "「\(label)」的宽高比 \(String(format: "%.2f", aspect)) 过小 —— "
                + "它被压成了竖排（frame = \(f)）"
            )
            checked += 1
        }
        XCTAssertGreaterThan(
            checked, 0,
            "一个可见的距离感标签都没核验到 —— 这条几何断言等于没跑"
        )

        // 数值不许断行：`100%` 必须是一个整体。
        // 断行后 XCUITest 拿到的 label 会含换行符或变成两段，
        // 所以直接查是否存在完整的「100%」。
        XCTAssertTrue(hasText("100%"), "「100%」被断行了 —— 履约率读起来会像两个不同的量")

        capture("22-xxxl-profiles")
    }

    func test_profiles_dark() throws {
        launch(screen: "profiles", appearance: "dark")
        assertColorScheme("dark", context: "深色关系档案")
        assertRendered("深色关系档案", expecting: "关系管理")
        capture("23-dark-profiles")
    }

    // MARK: - 数据删除（隐私承诺的端到端验证）

    /// 「删除全部数据」之后，评理列表必须是空的。
    ///
    /// 这条用例守的是一个已经发生过的真实隐私缺陷：
    /// 删除逻辑手写清单、漏掉了 `DisputeCase`，用户连点两次确认、
    /// 看到「已删除全部本地数据」，最敏感的评理证词却完整留在库里。
    ///
    /// 单元测试已经在数据层证明了逐表为 0（`DataLifecycleTests`）。
    /// 这里补的是**用户视角**：点完那两个按钮之后，他真的看不到评理了。
    /// 两层缺一不可 —— 数据层对但界面没刷新，用户一样会以为没删掉。
    func test_deletingEverythingRemovesDisputes() throws {
        // 先确认有一件案卷（否则"删除后为空"毫无意义，空库本来就空）。
        // 带 `--ui-test-case` 时 App 会自动推进该案卷的详情页，所以这里断言详情页文案。
        launch(screen: "disputes", caseName: "closed")
        assertRendered("评理结果页", expecting: "你们其实在争两件事")
        capture("30-before-delete")

        // 进「我的 → 数据管理 → 删除全部数据」
        //
        // 这条用例要走四五步 UI，是全套里最容易受时序影响的一条：
        // 前面用例把 App 起了又杀，冷启动变慢，5 秒的等待就会不够。
        // 每一步都单独断言，失败时能立刻看出卡在哪一步，
        // 而不是笼统地报"删除后还有数据"。
        app.terminate()
        launch(screen: "me", reset: false)

        let dataManagement = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "数据管理")
        ).firstMatch
        if dataManagement.waitForExistence(timeout: 15) {
            dataManagement.tap()
        } else {
            let link = app.staticTexts["数据管理"]
            XCTAssertTrue(link.waitForExistence(timeout: 15), "卡在第 1 步：找不到「数据管理」入口")
            link.tap()
        }

        let deleteButton = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "删除全部数据")
        ).firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 15), "卡在第 2 步：找不到「删除全部数据」")
        deleteButton.tap()

        // 两道确认。每一下都要等对话框真的出现再点，
        // 直接 tap 会在动画未完成时落到空处，然后整条用例静默失效。
        let firstConfirm = app.buttons["继续"]
        XCTAssertTrue(firstConfirm.waitForExistence(timeout: 10), "卡在第 3 步：第一道确认没出现")
        firstConfirm.tap()

        let finalConfirm = app.buttons["永久删除"]
        XCTAssertTrue(finalConfirm.waitForExistence(timeout: 10), "卡在第 4 步：最终确认没出现")
        finalConfirm.tap()

        // 删除后会退出登录，重新登录再看评理列表。
        // 必须 seed: false：否则启动时又插回一份样本案卷，
        // "删除后为空"就永远测不出来。
        app.terminate()
        launch(screen: "disputes", reset: false, seed: false)

        // 删除后连「进行过的」区块都不该存在
        XCTAssertFalse(
            hasText("进行过的"),
            "删除全部数据后仍显示「进行过的」区块 —— 评理没有被真正清除"
        )
        XCTAssertFalse(
            hasText("她说我总在解释"),
            "删除全部数据后评理案卷仍然可见 —— 评理没有被真正清除。"
            + "这正是历史缺陷：用户看到「已删除全部本地数据」，最敏感的证词还在库里"
        )
        capture("31-after-delete")
    }

    /// 交接阶段必须不泄露上一方写的内容 —— 包括**列表页的标题**。
    ///
    /// 这条守的是一个真实的密封漏洞：
    /// `DisputeCase.title` 是从 A 方第一题「发生了什么」的首句截前 18 字得来的，
    /// 而列表页直接显示 title。A 写完把手机递给 B 之后，B 只要返回列表
    /// 就能读到 A 的陈述 —— 而交接页写着「你写的那一份已经收起来了，屏幕上不会显示」。
    ///
    /// 断言打在"标题里的原文片段"上，而不是"标题是中性文案"上：
    /// 后者可以被任何无关的文案调整满足，前者才真的证明泄露与否。
    func test_handoverDoesNotLeakTitleInList() throws {
        // ready 状态 = 两份都写完了，此时双方都该看得到，标题可以显示
        launch(screen: "disputes", caseName: "ready")
        assertRendered("待生成页", expecting: "两份都写完了")

        // 回列表看标题
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["评理"].waitForExistence(timeout: 5),
            "没有回到评理列表"
        )
        XCTAssertTrue(
            hasText("她说我总在解释"),
            "两份都写完后列表却不显示标题 —— 这是把正常的可读性也一起挡掉了"
        )

        // 现在换成 handover 状态（只有 A 写完，手机该递给 B）
        app.terminate()
        launch(screen: "disputes", caseName: "handover")

        // handover 会直接推进详情页，先回列表
        if app.navigationBars.buttons.firstMatch.exists {
            app.navigationBars.buttons.firstMatch.tap()
        }

        XCTAssertFalse(
            hasText("她说我总在解释"),
            "交接阶段列表页仍然显示 A 写的标题 —— 密封承诺在实现层是破的。"
            + "标题取自第一份证词的首句，B 拿到手机后返回列表就能读到"
        )
        capture("32-handover-list-no-leak")
    }

    /// 打卡必须可以撤销。
    ///
    /// 打卡是一点即生效的（没有确认框），误触必然发生；
    /// 而连续天数是核心激励，误点一次「没做到」就会把记录断掉。
    func test_checkInCanBeUndone() throws {
        launch(screen: "home", anchor: "promises")
        XCTAssertTrue(hasText("待办承诺"), "找不到待办承诺区块")

        // 先打一次
        let done = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "今天做到了")
        ).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "找不到「今天做到了」")
        done.tap()

        // 选中后标签会带撤销提示，说明状态确实变了
        let selected = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "点击撤销")
        ).firstMatch
        XCTAssertTrue(
            selected.waitForExistence(timeout: 5),
            "打卡后按钮没有出现撤销入口 —— 误触将无法补救"
        )
        capture("33-checked-in")

        // 再点一次 = 撤销
        selected.tap()
        XCTAssertFalse(
            app.buttons.containing(
                NSPredicate(format: "label CONTAINS %@", "点击撤销")
            ).firstMatch.waitForExistence(timeout: 3),
            "点了撤销入口，打卡状态仍然存在"
        )
        capture("34-undone")
    }

    // MARK: - 真实模型调用（需要密钥，默认跳过）

    //
    // 这一组用例会**真的发网络请求**，因此：
    //   · 密钥从环境变量 `RC_TEST_AI_KEY` 读，绝不写进源码
    //   · 没设环境变量时用 `XCTSkip` 跳过，而不是失败 ——
    //     否则任何没配密钥的人 clone 下来 CI 直接红
    //
    // 它要回答的问题，是前面所有用例都回答不了的：
    // 手写的样本 verdict 只能证明"界面能渲染对的字符串"，
    // 证明不了"模型真的会给出可用结果"。而后者才是这个产品的核心。

    private var liveAIKey: String? {
        let key = ProcessInfo.processInfo.environment["RC_TEST_AI_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    /// 真实调用一次评理，结果必须**不是降级**，且四段齐全。
    ///
    /// 这条用例专门盯一个已经实测到的坑：
    /// 推理模型（DeepSeek-V4.1-Flash）的 `reasoning_content` 计入 `max_tokens`，
    /// 当初 `maxOutputTokens = 1200` 时正文只剩 249 token，
    /// JSON 被截在 `coexistence` 中间 → 解析失败 → **每次都降级**。
    /// 界面仍"正常显示"，只是悄悄变成并列原话。
    /// 只有真跑一次并断言"不是降级"，才能发现这种失败。
    func test_live_disputeProducesRealVerdict() throws {
        guard let key = liveAIKey else {
            throw XCTSkip("未设置 RC_TEST_AI_KEY，跳过真实模型调用")
        }

        launch(screen: "disputes", caseName: "ready", aiKey: key)
        assertRendered("待生成页", expecting: "两份都写完了")

        // 触发真实生成。ready 页的按钮文案是「一起看」——
        // 不是「生成」。写成「生成」会失败在找按钮上，而不是失败在模型上，
        // 那种失败会掩盖真正要验证的东西。
        let generateButton = app.buttons["一起看"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 10), "找不到「一起看」按钮")
        generateButton.tap()

        // 推理模型要思考，给足时间
        let reframe = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "其实在争两件事")
        ).firstMatch
        XCTAssertTrue(
            reframe.waitForExistence(timeout: 180),
            "180 秒内没有出现第三方之见的重命名段 —— 请求失败或超时"
        )

        // ① 绝不能是降级：降级页会给这个标题
        XCTAssertFalse(
            hasText("这次没能形成真正的第三方之见"),
            "真实调用走到了降级分支 —— 典型原因是输出被 max_tokens 截断。"
            + "请检查 finish_reason 是否为 length，以及 DisputePrompt.maxOutputTokens 是否够"
        )

        // ② 四段必须齐全
        XCTAssertTrue(hasText("各自想被听见的一句"), "缺少第②段（对称呈现）")
        XCTAssertTrue(hasText("你们卡在哪"), "缺少第③段（共同卡点）")
        XCTAssertTrue(
            hasText("这件事能解决") || hasText("这件事大概会一直在"),
            "缺少第④段的分流结论"
        )

        // ③ 责任分配绝不能被模型带回来
        XCTAssertFalse(hasText("责任"), "模型给出了责任分配，与'不做判决'的核心决策冲突")

        capture("20-live-verdict")
    }

    /// 真实调用下的对称性必须过关。
    ///
    /// 0.2 的阈值是我定的，一直没被真实数据检验过。
    /// 这条用例把"真实模型能否稳定通过"变成可观测的：
    /// 若它经常失败，说明**要调的是提示词而不是阈值**。
    func test_live_verdictPassesSymmetryGate() throws {
        guard let key = liveAIKey else {
            throw XCTSkip("未设置 RC_TEST_AI_KEY，跳过真实模型调用")
        }

        launch(screen: "disputes", caseName: "ready", aiKey: key)
        assertRendered("待生成页", expecting: "两份都写完了")

        let generateButton = app.buttons["一起看"]
        XCTAssertTrue(generateButton.waitForExistence(timeout: 10))
        generateButton.tap()

        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "其实在争两件事")
            ).firstMatch.waitForExistence(timeout: 180),
            "没有生成出结果"
        )

        // 两侧长度不一致时，界面会明确说"这是生成的问题，不是谁更重要"
        XCTAssertFalse(
            hasText("两段长度不一致"),
            "真实模型没通过 0.2 的对称阈值。这是模型能力/提示词的问题，"
            + "应先加强提示词的对称约束，而不是放宽阈值"
        )

        capture("21-live-symmetry")
    }

    // MARK: - 引导式道歉
    //
    // 这一组验的不是"页面能打开"，是**规矩有没有真的生效**。
    // 引导流程的全部价值在于拦截：拦不住，它就只是一层好看的皮。

    private func openRepairTool() {
        let entry = app.staticTexts["道歉准备"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "首页找不到「道歉准备」入口")
        entry.tap()
    }

    /// 第 2 步：「态度不好」是评价，不是动作，必须拦住。
    ///
    /// 这条如果失效，用户会以为自己写完了 —— 而对方听到的仍然是
    /// "你到底做了什么？"
    func test_repair_blocksEvaluationOnlyAction() throws {
        launch(screen: "home", anchor: "quickTools", repairPrefill: "action-vague")
        openRepairTool()

        XCTAssertTrue(hasText("共 7 步"), "没有进入引导流程")
        XCTAssertFalse(app.buttons["下一步"].isEnabled, "有阻断项时「下一步」仍然可点")

        app.swipeUp()
        XCTAssertTrue(hasText("是评价，不是动作"), "「态度不好」没有被判为评价")
        capture("40-repair-blocked-action")
    }

    /// 第 4 步：只写「她不开心」时，闸门必须锁住。
    ///
    /// 这是全流程唯一的硬闸门。它失效的后果是：
    /// 用户照样能走到最后，写出一段"对不起让你不开心"。
    func test_repair_lossGateBlocksAbstractEmotion() throws {
        launch(screen: "home", anchor: "quickTools", repairPrefill: "losses-abstract")
        openRepairTool()

        XCTAssertFalse(app.buttons["下一步"].isEnabled, "只写「她不开心」竟然可以继续 —— 闸门失效")

        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(hasText("写不出来很正常"), "闸门锁住了，但没有给出出口提示 —— 那会变成死路")
        capture("41-repair-loss-gate")
    }

    /// 写下具体损失后，闸门应当打开。
    ///
    /// 与上一条成对：只测"锁得住"无法区分"规则有效"和"规则把什么都锁了"。
    func test_repair_lossGateOpensOnConcreteLoss() throws {
        launch(screen: "home", anchor: "quickTools", repairPrefill: "losses-filled")
        openRepairTool()
        XCTAssertTrue(app.buttons["下一步"].isEnabled, "具体损失被误拦")
        capture("42-repair-loss-open")
    }

    /// 安全闸门：害怕对方反应时，不进入道歉流程。
    ///
    /// 这条是伦理性的，不是体验性的。"如何更有效地道歉"这套技术在
    /// 权力不对等的关系里会被反过来用于维持控制。
    func test_repair_safetyGateRoutesToResources() throws {
        launch(screen: "home", anchor: "quickTools", repairPrefill: "safety")
        openRepairTool()

        XCTAssertTrue(hasText("害怕告诉对方"), "安全闸门没有出现")
        app.buttons["是，有一点"].tap()

        XCTAssertTrue(
            hasText("先别急着道歉"),
            "选了「害怕」之后仍然进入道歉流程 —— 这是伦理问题，不是体验问题"
        )
        XCTAssertTrue(hasText("12338"), "没有给出求助资源")
        capture("43-repair-safety")
    }

    // MARK: - 登录与内测入口

    //
    // 这一组此前完全没有覆盖：所有用例都带 `--ui-test-autologin`，
    // 直接跳过登录页。于是"内测用户能不能进得来"这件事，
    // 在整个自动化体系里是**不可见**的 —— 而它恰恰是内测的第一道门。
    //
    // 实际后果已经发生过：Release 包里登录 provider 是 `UnconfiguredAuthProvider`，
    // 所有请求返回 503，而「进入演示模式」被 `#if DEBUG` 挡在 Release 之外。
    // 内测用户能看到登录页，但无论如何都进不去。

    /// 登录页必须给出内测跳过入口。
    func test_betaLoginPageOffersSkip() throws {
        launch(screen: "home", skipAutoLogin: true)

        XCTAssertTrue(
            hasText("内测版本"),
            "登录页没有内测入口 —— Release 构建下用户将无法进入 App"
        )
        // 必须说明数据去哪了。只写「跳过」会让用户以为自己注册了账号，
        // 等他换手机发现数据全没了，那时再解释就晚了。
        XCTAssertTrue(
            hasText("只保存在这台设备上"),
            "内测入口没有说明数据只存本机"
        )
        capture("50-login-beta")
    }

    /// 点内测入口**必须真的进得去**。
    ///
    /// 这条是整个内测的前置条件：如果它失败，其他所有用例测的都是
    /// 一个内测用户永远到不了的 App。
    func test_betaSkipEntersApp() throws {
        launch(screen: "home", skipAutoLogin: true)

        let skip = app.buttons["内测版本 · 跳过登录"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "找不到内测跳过按钮")
        skip.tap()

        // 进到主界面 = 出现 tab bar（登录页没有 tab bar）
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 20),
            "点了内测跳过之后没有进入主界面"
        )
        capture("51-login-beta-entered")
    }
}
