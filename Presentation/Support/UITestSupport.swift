//
//  UITestSupport.swift
//  RelationshipCopilot
//
//  仅 DEBUG 生效的界面核验辅助。
//
//  为什么需要它：本仓库历史问题之一是"编译通过、断言全绿，但界面是坏的"
//  （例如首页给新用户显示 0 分、深色模式下露出白卡片）。这类问题只能靠
//  **真实渲染 + 逐屏查看来发现**，而不是靠单元测试。
//
//  因此提供以下几个启动参数，让自动化脚本可以直达指定页面并截图：
//    --ui-test-autologin        跳过登录（使用演示账号）
//    --ui-test-seed             注入一组样本数据（2 个人物、2 条承诺、1 条记录）
//    --ui-test-screen=home|disputes|profiles|promises|me  指定初始 tab
//    --ui-test-case=collecting|handover|ready|solo|closed|perpetual|degraded|blocked
//                               按指定状态造一件案卷，并直接推进详情页
//
//  `--ui-test-case` 存在的原因：评理有 5 个屏，靠脚本点进去要输入四段 200 字文本，
//  而且点击路径本身会掩盖"某一屏其实渲染错了"。按状态造数据是更可靠的核验方式。
//
//  整个文件被 `#if DEBUG` 包住，Release 构建中不存在这些代码路径，
//  也不会出现"生产包里带测试后门"的问题。
//

#if DEBUG
import Foundation
import SwiftData
import SwiftUI

enum UITestSupport {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-autologin")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-seed")
            || initialCaseStateKey != nil
    }

    static var shouldAutoLogin: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-autologin")
    }

    static var shouldSeed: Bool {
        // `--ui-test-no-seed` 显式压过一切播种条件。
        // 用于「验证数据真的被删干净了」这类用例：启动时若又补一份样本，
        // 就永远看不到空状态，失败还会误指向产品缺陷。
        if ProcessInfo.processInfo.arguments.contains("--ui-test-no-seed") {
            return false
        }
        return ProcessInfo.processInfo.arguments.contains("--ui-test-seed") || initialCaseStateKey != nil
    }

    /// 解析 `--ui-test-reset`：启动时先清空本地库，再播样本数据。
    ///
    /// **这是必需项，不是可选项。** 不清理的后果已经实测到过：
    /// `test_adoptingVerdictAsPromiseCreatesPromise` 点一次「沉淀为承诺」后，
    /// 案卷里就永久多了一条 `linkedPromises`；后续用例再进同一件案卷时，
    /// 按钮显示的已经是「已加进承诺」，于是断言「找不到『记成一条承诺』」失败。
    ///
    /// 也就是说：**用例会依赖上一条用例留下的状态**，单独跑绿、全量跑红。
    /// 这和之前字号来自模拟器持久状态导致的假绿是同一类错误——
    /// 测试必须能控制自己的初始条件，而不是继承上一次运行的残留。
    static var shouldResetBeforeSeeding: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-reset")
    }

    /// 解析 `--ai-direct-key=<key>`，把密钥写入 Keychain。
    ///
    /// 只为一个场景存在：自动化验证真实的模型调用。
    /// 手动使用时请走「设置 → 调试：直连密钥」那个输入框，不要把密钥写进命令行。
    ///
    /// 仍然遵守同一条铁律：**密钥只落在 Keychain，不落源码、不落 Info.plist、不落 IPA。**
    static var injectedDirectKey: String? {
        guard let value = argumentValue("--ai-direct-key=") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 解析 `--ui-test-clear-auth`：启动时清掉 Keychain 里的登录态。
    ///
    /// 为什么需要：iOS 的 Keychain **在卸载 App 后仍然保留**（这是系统行为，
    /// 不是缺陷）。于是"卸载重装"并不会回到登录页 —— 实测过：
    /// 清空模拟器后装 Release 包才第一次看到真实首屏。
    ///
    /// 要验证「登录页」和「内测跳过登录」就必须先真的处于未登录状态，
    /// 否则用例会安静地测一个已经登录的 App，然后全绿。
    static var shouldClearAuth: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-clear-auth")
    }

    /// 解析 `--ui-test-screen=xxx`
    /// 解析 `--ui-test-repair-prefill=...`：把「道歉准备」直接推进到某个状态。
    ///
    /// 存在的理由很具体：XCUITest 的 `typeText` 对中文并不可靠，敲不进去时
    /// 测试会失败在"字没打上"，而不是失败在"闸门没拦住"上 ——
    /// 那种失败会把真正要验证的东西藏起来。
    static var repairPrefill: String? {
        argumentValue("--ui-test-repair-prefill=")
    }

    static var initialTab: AppRouter.Tab? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--ui-test-screen=") {
            let value = argument.replacingOccurrences(of: "--ui-test-screen=", with: "")
            switch value {
            case "home":      return .home
            case "disputes":  return .disputes
            case "profiles":  return .profiles
            case "promises":  return .promises
            case "me":        return .me
            default:          return nil
            }
        }
        return nil
    }

    /// 解析 `--ui-test-anchor=quicktools|promises|recording|recent|analysis`。
    ///
    /// 为什么需要它：大字号下首页非常长，用 XCUITest 模拟拖拽去"滚到某个区块"
    /// 极不可靠 —— 拖拽会产生惯性，一次跨过整段；`.fast` 更是直接跳过整屏。
    /// 让 App 侧用 `ScrollViewReader` 精确滚到锚点，测试才能稳定复现。
    static var initialAnchor: String? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--ui-test-anchor=") {
            return String(argument.dropFirst("--ui-test-anchor=".count))
        }
        return nil
    }

    /// 解析 `--ui-test-case=closed|blocked|collecting|handover|ready|degraded|perpetual`。
    ///
    /// 评理流程有 5 个屏，靠脚本一路点击进去太慢（要输入四段 200 字文本），
    /// 而且点击路径本身会掩盖"某一屏其实渲染错了"的问题。
    /// 所以这里直接按状态造案卷，再用导航路径一步推进去。
    static var initialCaseStateKey: String? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--ui-test-case=") {
            return String(argument.dropFirst("--ui-test-case=".count))
        }
        return nil
    }

    /// 解析 `--ui-test-font=xxxl`，由 App 自己设置动态字体档位。
    ///
    /// **为什么不让测试用 `simctl ui content_size` 设：**
    /// 那条命令改的是模拟器的持久状态，跑完不会自动还原。
    /// 于是"上一条命令设过 XXXL"变成了一个**隐式前置条件**——
    /// 一旦某次在 `content_size medium` 下跑全量，`test_xxxl_*` 三个用例
    /// 会在普通字号下截图、并且**照样通过**（这就是假绿）。
    /// 更糟的是它无法自证：测试不知道自己到底跑在哪个字号上。
    ///
    /// 改成启动参数后，字号随 App 启动确定、跟着进程走，用完即弃。
    static var forcedDynamicTypeSize: DynamicTypeSize? {
        guard let raw = argumentValue("--ui-test-font=") else { return nil }
        switch raw {
        case "xxxl": return .accessibility3
        case "xxl":  return .accessibility1
        default:     return nil
        }
    }

    private static func argumentValue(_ prefix: String) -> String? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix(prefix) {
            return String(argument.dropFirst(prefix.count))
        }
        return nil
    }

    /// 供测试读取的档位标签。测试断言的是**这个值**，
    /// 而不是"我记得我设过 XXXL"——后者正是假绿的来源。
    static var fontProbeLabel: String {
        forcedDynamicTypeSize == .accessibility3 ? "xxxl" : "default"
    }

    /// 由 `--ui-test-case=` 反查出的样本案卷 id（`seedIfNeeded` 写入）。
    /// 因为 `seedIfNeeded` 可能因幂等守卫提前返回，这里用固定 UUID 保证可预测。
    static var initialCaseID: UUID? {
        guard let key = initialCaseStateKey else { return nil }
        return seedCaseIDs[key]
    }

    private static let seedCaseIDs: [String: UUID] = [
        "collecting": UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        "handover":   UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        "ready":      UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        "closed":     UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        "perpetual":  UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        "degraded":   UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
        "blocked":    UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
        "solo":       UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    ]

    /// 注入样本数据。
    ///
    /// 基础数据（人物/承诺/录音）用「表里有没有数据」做幂等；
    /// 案卷样本用**固定 UUID** 做幂等 —— 因为要按状态名反复截图，
    /// 每次冷启动不能因为「已经有数据了」而跳过案卷插入。
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        guard shouldSeed else { return }

        // 先清库再播数据 —— 保证每条用例都从同一个已知初始状态出发。
        // 不清理会让用例互相污染：前一条点了「沉淀为承诺」，后一条就看不到那个按钮。
        if shouldResetBeforeSeeding {
            try? DataEraser.eraseAll(in: context)
            // 顺带清掉与数据无关但会影响断言的缓存状态
            WidgetDataStore.clear()
        }

        let partner = seedBaseData(context: context)
        seedCaseIfNeeded(context: context, partner: partner)

        try? context.save()
        DataMaintenance.syncWidget(context: context)
    }

    @MainActor
    private static func seedBaseData(context: ModelContext) -> Profile? {
        let existing = (try? context.fetch(FetchDescriptor<Profile>())) ?? []
        if let first = existing.first { return first }

        let partner = Profile(name: "小林", relationshipType: RelationshipType.partner.rawValue)
        partner.birthday = Calendar.current.date(byAdding: .month, value: -8, to: Date())
        partner.anniversary = Calendar.current.date(byAdding: .year, value: -2, to: Date())
        partner.notes = "喜欢安静地被陪着，不喜欢被追问。"
        partner.setIntimacy(6)
        context.insert(partner)

        let family = Profile(name: "妈妈", relationshipType: RelationshipType.family.rawValue)
        family.setIntimacy(4)
        context.insert(family)

        let promise1 = Promise(content: "这周陪她散步两次", promisor: "user", promisee: "小林")
        promise1.profile = partner
        promise1.deadline = Calendar.current.date(byAdding: .day, value: 3, to: Date())
        context.insert(promise1)

        // 造 3 天连续打卡，让「连续天数」「履约率」有真实数据可展示
        for offset in 0..<3 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let record = FulfillmentRecord(
                recordDate: Calendar.current.startOfDay(for: day),
                status: FulfillmentStatus.fulfilled.rawValue
            )
            record.detectionSource = "user_self_report"
            record.promise = promise1
            context.insert(record)
        }
        promise1.recalculateStats()

        let promise2 = Promise(content: "吵架后 24 小时内主动开口", promisor: "user", promisee: "小林")
        promise2.profile = partner
        context.insert(promise2)

        let session = RecordingSession(
            sessionType: .conflict,
            profile: partner,
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-3300)
        )
        session.transcription = "（样本数据）她说最近总是我先睡着，觉得被忽略。我解释是加班太累，语气有点冲。"
        session.analysisResult = AnalysisResult(
            emotionScore: 78,
            communicationPatterns: ["愿意解释自己的处境", "没有回避问题"],
            recommendations: ["先说感受再说事实", "约定一个睡前十分钟的固定交流"],
            summary: "沟通还在，但都在讲道理，情绪没被接住。",
            keywords: ["容易先解释再听", "疲惫时语气会变硬"],
            emotionalTrend: "下降",
            communicationQuality: "一般"
        )
        session.status = SessionStatus.analyzed.rawValue
        context.insert(session)

        return partner
    }

    // MARK: 案卷样本

    /// 按 `--ui-test-case=` 造一份对应状态的案卷。固定 UUID，存在即跳过。
    @MainActor
    private static func seedCaseIfNeeded(context: ModelContext, partner: Profile?) {
        guard let key = initialCaseStateKey, let targetID = seedCaseIDs[key] else { return }

        let all = (try? context.fetch(FetchDescriptor<DisputeCase>())) ?? []
        guard !all.contains(where: { $0.id == targetID }) else { return }

        let newCase = DisputeCase(
            title: sampleTitle(for: key),
            mode: key == "solo" ? .solo : .sameDevice,
            // 固定 id：这样 `--ui-test-case=closed` 可以反复截图同一件。
            id: targetID
        )
        newCase.profile = partner
        context.insert(newCase)

        let sideA = sampleTestimonyA()
        switch key {
        case "collecting":
            break

        case "handover":
            newCase.sideA = sideA
            newCase.state = .waitingForB

        case "ready":
            newCase.sideA = sideA
            newCase.sideB = sampleTestimonyB()
            newCase.state = .ready

        case "solo":
            newCase.sideA = sideA
            newCase.state = .ready

        case "closed":
            newCase.sideA = sideA
            newCase.sideB = sampleTestimonyB()
            newCase.state = .closed
            newCase.verdict = sampleVerdict(solvable: true)
            newCase.closedAt = Date()

        case "perpetual":
            newCase.sideA = sideA
            newCase.sideB = sampleTestimonyB()
            newCase.state = .closed
            newCase.verdict = sampleVerdict(solvable: false)
            newCase.closedAt = Date()

        case "degraded":
            // 降级路径：解析彻底失败时并列原话，不做任何推断。
            newCase.sideA = sideA
            newCase.sideB = sampleTestimonyB()
            newCase.state = .closed
            newCase.verdict = DisputeVerdict(
                reframe: "（降级）你们各自写的内容如下，没有做归纳。",
                needA: "我希望她能先问我一句今天怎么样，而不是直接说我又忘了。",
                needB: "我想他能自己记住这件事，而不是每次都要我提醒才动。",
                stuckPoint: "（降级）这次没有形成共同卡点的判断。",
                solvability: .solvable,
                action: nil
            )
            // 关键：降级标记要真的落盘，否则这一屏和正常结果长得一样。
            newCase.isDegradedVerdict = true
            newCase.closedAt = Date()

        case "blocked":
            newCase.sideA = sideA
            newCase.state = .blocked
            newCase.safetyConcerns = [.violence]

        default:
            break
        }
    }

    private static func sampleTitle(for key: String) -> String {
        switch key {
        case "blocked":  return "昨天晚上那件事"
        case "solo":     return "我好像总是先解释"
        default:         return "她说我总在解释，不在听"
        }
    }

    private static func sampleTestimonyA() -> DisputeTestimony {
        DisputeTestimony(
            happened: "昨天她跟我说公司里被领导当众批评了，我听完就说「那你下次提前把材料准备好」，她当时就没再说话，晚上自己先睡了。",
            hurtMost: "最难受的是她说「跟你说也没用」。我不是不在乎，我是真的想帮她想办法。",
            request: "我希望她下次觉得我在讲道理的时候，直接说一句「我现在不想听建议」，我就停。",
            myPart: "我听得太急了。她开口的前三十秒，我脑子里已经在想解决方案，没有先接住她的情绪。"
        )
    }

    private static func sampleTestimonyB() -> DisputeTestimony {
        DisputeTestimony(
            happened: "我下班回来说了白天被批评的事，他马上开始教我应该怎么做，一条一条地分析。我说了两句就不想说了。",
            hurtMost: "难受的不是他给建议，是他一次都没问过我那时候什么感觉。",
            request: "我希望他先陪我待一会儿，别急着解决。哪怕只说一句「那一定很难受」。",
            myPart: "我也没讲清楚。我习惯说「没事」，他大概真的以为我不需要被安慰。"
        )
    }

    /// 可解决型 / 永久型两种样本。
    ///
    /// 注意 needA / needB 字数刻意接近（对称性阈值 ≥0.8），
    /// 否则 `isDeliverable` 为 false，界面会落到「生成有问题」的提示上。
    private static func sampleVerdict(solvable: Bool) -> DisputeVerdict {
        if solvable {
            return DisputeVerdict(
                reframe: "你们其实在争两件事。你在争「怎么把问题解决掉」，她在争「有没有人先接住我」。这两件事都有道理，但它们不在同一个频道上，所以谁先开口都像在错位。",
                needA: "他想被承认是好意的：他给建议是因为在乎，不是因为不耐烦。",
                needB: "她想被承认的是感受：她要的不是方案，是有人先陪她待一会儿。",
                stuckPoint: "你们卡在「谁先让步」上。他一开口就是方案，她一沉默就被读成拒绝，于是两个人都觉得对方没在听。",
                solvability: .solvable,
                action: "这周找一次，她说完之后你先只说一句「那一定很难受」，然后停十秒。不解释、不建议、不追问。"
            )
        }
        return DisputeVerdict(
            reframe: "你们其实在争两件事。你在争「说了就要有用」，她在争「说了就要被听见」。这两件事都有道理，但它们不在同一个频道上，所以每次都以沉默收场。",
            needA: "他想被承认是好意的：他急着想办法，是因为见不得她难受。",
            needB: "她想被承认的是感受：她开口不是求助，是想有人站在她这边。",
            stuckPoint: "你们卡在节奏上。他需要「有事可做」才安心，她需要「先被接住」才开口，这两种节奏本身没有对错，但撞在一起就都落空。",
            solvability: .perpetual,
            coexistence: "以后她开口时，先约定一句话：「我现在只想被听，不用给办法。」他说完这句就停；她说完想听建议时，再补一句「你说说看」。"
        )
    }
}
#endif
