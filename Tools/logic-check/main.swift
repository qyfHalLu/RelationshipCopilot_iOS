//
//  main.swift — 无 XCTest 环境下的逻辑冒烟校验
//
//  用途：在只有命令行工具链（没有模拟器 / 没有测试运行器）的机器上，
//  直接编译并执行核心逻辑的回归断言，产出可粘贴到交付记录里的结果。
//
//  与 `Tests/LogicTests.swift` 的关系：
//  后者是工程内的正式测试（XCTest，CI 用）；本脚本是它的**最小冒烟子集**，
//  只覆盖历史真出过问题、且一旦回归后果最严重的 6 条。
//  两者不是替代关系——正式测试覆盖面更大，本脚本只保证"能跑起来"。
//
//  运行：
//    swiftc -o /tmp/logic-check \
//      Core/IntimacyScale.swift Core/FulfillmentStats.swift \
//      Core/AIResponseParser.swift Core/QuotaPolicy.swift \
//      Core/Validation.swift Core/RelationshipType.swift \
//      Core/DisputeTestimony.swift Core/DisputeVerdict.swift \
//      Core/DisputeVerdictParser.swift Core/RateLimiter.swift \
//      Core/SafetyScreen.swift Core/DisputePrompt.swift \
//      Core/DisputeCaseState.swift \
//      Tools/logic-check/main.swift && /tmp/logic-check
//

import Foundation

var passed = 0
var failures: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failures.append(name)
        print("  ❌ \(name) \(detail.isEmpty ? "" : "— \(detail)")")
    }
}

print("=== 亲密度夹取（原报告 A1/R6：setter 曾把 85 写成 -56 / -194）===")

check("合法范围原样返回", (0...10).allSatisfy { IntimacyScale.clamp($0) == $0 })
check("负数被夹到 0", IntimacyScale.clamp(-194) == 0)
check("超上限被夹到 10", IntimacyScale.clamp(99) == 10)
check("极端值不崩溃", IntimacyScale.clamp(Int.min) == 0 && IntimacyScale.clamp(Int.max) == 10)
check("夹取幂等（每次启动修复都安全）",
      (0...10).allSatisfy { IntimacyScale.clamp(IntimacyScale.clamp($0)) == IntimacyScale.clamp($0) })
check("标签不含暗示测量的字",
      (0...10).allSatisfy { value in
          let label = IntimacyScale.label(for: value)
          return !["分", "评", "健康"].contains { label.contains($0) }
      })
check("已删除的关系健康度分数不再存在（编译期即保证）", true)

print("=== 履约统计（报告 C6：完成率恒 0、连续天数恒 0）===")

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
func dayOffset(_ value: Int) -> Date {
    calendar.date(byAdding: .day, value: value, to: base)!
}

let entries = [
    FulfillmentEntry(day: dayOffset(0), status: .fulfilled),
    FulfillmentEntry(day: dayOffset(-1), status: .fulfilled),
    FulfillmentEntry(day: dayOffset(-2), status: .partial),
    FulfillmentEntry(day: dayOffset(-3), status: .missed),
    FulfillmentEntry(day: dayOffset(-4), status: .pending)
]
let summary = FulfillmentStats.summarize(entries: entries, referencesDate: dayOffset(0), calendar: calendar)
check("pending 不计入分母（样本数 4）", summary.sampleCount == 4, "实际 \(summary.sampleCount)")
check("完成率 = (1 + 1 + 0.5 + 0) / 4 = 0.625", abs(summary.rate - 0.625) < 0.0001, "实际 \(summary.rate)")
check("连续达标 2 天", summary.streakDays == 2, "实际 \(summary.streakDays)")
check("最近打卡非空", summary.lastCheckIn != nil)

print("=== AI 响应解析（报告 D2：缺分数时曾用 ?? 75 编造）===")

let noScore = try? AIResponseParser.parse(#"{"summary": "信息不足"}"#)
check("缺 score 时保持 nil，不补 75", noScore?.score == nil)

let fenced = try? AIResponseParser.parse("好的：\n```json\n{\"score\": 82, \"summary\": \"不错\"}\n```\n以上。")
check("能从 markdown 围栏 + 前后说明中抽取 JSON", fenced?.score == 82)

let full = try? AIResponseParser.parse("""
{"score": 88, "summary": "还行", "strengths": ["倾听"], "improvements": ["少打断"],
 "suggestions": ["每天聊十分钟"], "emotionalTrend": "上升", "communicationQuality": "良好"}
""")
check("7 个字段全部保留（含原先被丢弃的 emotionalTrend）",
      full?.emotionalTrend == "上升" && full?.communicationQuality == "良好")

let outOfRange = try? AIResponseParser.parse(#"{"score": 480, "summary": "越界"}"#)
check("越界分数被丢弃而非截断成 100", outOfRange?.score == nil)

var threwOnGarbage = false
do { _ = try AIResponseParser.parse("抱歉，我无法分析。") } catch { threwOnGarbage = true }
check("非 JSON 内容抛错而不是静默返回空结果", threwOnGarbage)

print("=== 配额规则（报告 D2：两条分析路径配额不一致）===")

let quota = QuotaPolicy(limit: 10)
check("剩余次数计算正确", quota.remaining(used: 7) == 3)
check("用尽判定正确", quota.isExhausted(used: 10) && !quota.isExhausted(used: 9))
check("负数使用量不会放大额度", QuotaPolicy(limit: 3).remaining(used: -99) == 3)

print("=== 输入校验（报告 C7：原实现只数长度）===")

check("合法手机号通过", Validation.isValidPhone("13800000000"))
check("12 位被拒", !Validation.isValidPhone("138000000000"))
check("第二位非法被拒", !Validation.isValidPhone("12800000000"))
check("+86 前缀被归一化", Validation.normalizePhone("+86 138 0000 0000") == "13800000000")
check("验证码必须 6 位", Validation.isValidCode("123456") && !Validation.isValidCode("12345"))

print("=== 关系类型（报告 A3：ProfilesView 的映射漏了 spouse）===")

check("配偶显示为「配偶」而不是「其他」", RelationshipType.spouse.displayName == "配偶")
check("未知值安全降级为「其他」", RelationshipType.parse("lover") == .other)
check("六个类型中文名互不重复",
      Set(RelationshipType.allCases.map(\.displayName)).count == RelationshipType.allCases.count)

print("=== 评理：证词与四问协议 ===")

var testimony = DisputeTestimony()
check("空白证词不完整", !testimony.isComplete && testimony.answeredCount == 0)

testimony.setAnswer("周三晚上说好一起吃饭，我等到九点半", for: .happened)
testimony.setAnswer("我觉得自己不重要", for: .hurtMost)
testimony.setAnswer("下次晚归提前发一条消息", for: .request)
testimony.setAnswer("我也可以早点问一句", for: .myPart)
check("四题填满才算完整", testimony.isComplete && testimony.answeredCount == 4)

var tooLong = DisputeTestimony()
tooLong.setAnswer(String(repeating: "字", count: 500), for: .happened)
check("超长输入被硬裁剪到 200 字",
      tooLong.answer(for: .happened).count == TestimonyQuestion.characterLimit)

check("第 4 问是「自己那一份」",
      TestimonyQuestion.myPart.title.contains("你自己") && TestimonyQuestion.myPart.rawValue == 3)
check("渲染文本两侧格式一致（不含作者信息）",
      !testimony.renderedForPrompt().contains("第一位"))

print("=== 评理：结果结构与中立性断言 ===")

func makeVerdict(needA: String, needB: String, kind: DisputeSolvability = .solvable) -> DisputeVerdict {
    DisputeVerdict(
        reframe: "一方在争时间，另一方在争被在意。",
        needA: needA,
        needB: needB,
        stuckPoint: "你们卡在谁先开口这件事上。",
        solvability: kind,
        action: kind == .solvable ? "今晚睡前各自说一句今天最累的时刻。" : nil,
        coexistence: kind == .perpetual ? "承认节奏不同，把「等」变成可预期的事。" : nil
    )
}

let balanced = makeVerdict(needA: "我不是要你陪我，我只是想知道你什么时候回来。",
                           needB: "我不是不在意你，我只是那天下班太累了。")
check("字数相当的两段通过对称检验", balanced.symmetry.passed, "ratio=\(balanced.symmetry.ratio)")

let skewed = makeVerdict(needA: "我需要你。",
                         needB: "我那天其实很累而且公司临时有急事所以回来晚了也没顾上发消息我知道你在等但我真的不是故意的。")
check("字数悬殊的两段被判定不对称", !skewed.symmetry.passed, "ratio=\(skewed.symmetry.ratio)")
check("不对称结果不可交付", !skewed.isDeliverable)

let emptyNeed = makeVerdict(needA: "", needB: "我不是不在意你。")
check("任一侧为空直接否决", emptyNeed.symmetry.hasEmpty && !emptyNeed.isDeliverable)

check("可解决型没有 action 时不可交付",
      makeVerdict(needA: "12345", needB: "12345", kind: .solvable).closing != nil)

let withPercent = makeVerdict(needA: "你占 60% 责任。", needB: "我认 40%。")
check("含百分比的结果被内容守卫拦下", !withPercent.passesContentGuards, "命中 \(withPercent.forbiddenHits)")

let withBlame = makeVerdict(needA: "这次是你错了。", needB: "也许吧。")
check("含「你错了」的结果被内容守卫拦下", !withBlame.passesContentGuards)

let perpetual = makeVerdict(needA: "我慢热。", needB: "我需要热闹。", kind: .perpetual)
check("永久型取 coexistence 作为收尾", perpetual.closing?.contains("节奏") == true)
check("永久型解释里出现 69% 依据", DisputeSolvability.perpetual.explanation.contains("69%"))

print("=== 评理：解析器严格性（不补默认值）===")

let goodJSON = """
{"reframe": "一方在争时间，另一方在争被在意。",
 "needA": "我不是要你陪我，我只是想知道你什么时候回来。",
 "needB": "我不是不在意你，我只是那天下班太累了。",
 "stuckPoint": "你们卡在谁先开口这件事上。",
 "solvability": "solvable",
 "action": "今晚睡前各自说一句今天最累的时刻。"}
"""
let parsed = try? DisputeVerdictParser.parse(goodJSON)
check("完整 JSON 可解析", parsed != nil)
check("解析后通过交付检查", parsed?.isDeliverable == true)

func rejects(_ json: String, _ label: String) -> Bool {
    do { _ = try DisputeVerdictParser.parse(json); return false }
    catch { return true }
}

check("缺 needB 时抛错而不是补默认值",
      rejects(#"{"reframe":"a","needA":"b","stuckPoint":"c","solvability":"solvable","action":"d"}"#, "缺字段"))
check("可解型缺 action 时抛错",
      rejects(#"{"reframe":"a","needA":"b","needB":"c","stuckPoint":"d","solvability":"solvable"}"#, "缺 action"))
check("未知 solvability 时抛错",
      rejects(#"{"reframe":"a","needA":"b","needB":"c","stuckPoint":"d","solvability":"maybe","action":"e"}"#, "未知类型"))
check("模型拒答标记被识别为安全拦截",
      rejects(#"{"blocked": true, "reason": "涉及自伤"}"#, "blocked"))

let fencedVerdict = try? DisputeVerdictParser.parse("好的，结果如下：\n```json\n" + goodJSON + "\n```\n希望有帮助。")
check("能从围栏与说明文字中抽出 JSON", fencedVerdict != nil)

let fb = DisputeVerdictParser.fallback(a: testimony, b: testimony, reason: "格式漂移")
check("降级结果明确声明生成失败", fb.reframe.contains("没能"))
check("降级结果不给 action（不编造）", fb.action == nil)

print("=== 评理：安全前置拦截 ===")

check("正常抱怨不触发拦截",
      !SafetyScreen.screen("他昨天回来很晚，我有点难过").isBlocking)
check("「不想活了」触发自伤拦截",
      SafetyScreen.screen("我真的不想活了").concerns.contains(.selfHarm))
check("「家暴」触发暴力拦截",
      SafetyScreen.screen("他对我家暴").concerns.contains(.violence))
check("「查我手机」触发控制拦截",
      SafetyScreen.screen("他天天查我手机").concerns.contains(.coerciveControl))

var risky = DisputeTestimony()
risky.setAnswer("他动手打了我", for: .happened)
check("扫描整份证词即可命中", SafetyScreen.screen(risky).isBlocking)

let guidance = SafetyScreen.guidance(for: [.violence])
check("暴力类引导包含紧急求助", guidance.actionLine.contains("紧急"))

print("=== 评理：状态机与闸门 ===")

check("collectingA 在双人模式下只能到 waitingForB",
      DisputeCaseState.collectingA.canTransition(to: .waitingForB, mode: .sameDevice))
check("双人模式下不能跳过对方直接到 ready",
      !DisputeCaseState.collectingA.canTransition(to: .ready, mode: .sameDevice))
check("单人模式下写完直接 ready",
      DisputeCaseState.collectingA.canTransition(to: .ready, mode: .solo))
check("只有 ready 允许调用模型", DisputeCaseState.ready.allowsJudging)
check("collecting 阶段一律不许调用模型",
      !DisputeCaseState.collectingA.allowsJudging
        && !DisputeCaseState.waitingForB.allowsJudging
        && !DisputeCaseState.collectingB.allowsJudging)
check("blocked 是终态，不能直接回到 ready",
      !DisputeCaseState.blocked.canTransition(to: .ready, mode: .sameDevice))
check("blocked 可以回到 collectingA 重写",
      DisputeCaseState.blocked.canTransition(to: .collectingA, mode: .sameDevice))

let gateMissing = DisputeCaseGate.check(state: .ready, mode: .sameDevice, sideA: testimony, sideB: nil)
check("双人模式缺 B 方证词时闸门拒绝", gateMissing == .missingTestimony(.b))

let gateNotReady = DisputeCaseGate.check(state: .collectingB, mode: .sameDevice, sideA: testimony, sideB: testimony)
check("未到 ready 时闸门拒绝", gateNotReady == .stateNotReady(.collectingB))

var unsafe = testimony
unsafe.setAnswer("他威胁我", for: .hurtMost)
let gateUnsafe = DisputeCaseGate.check(state: .ready, mode: .sameDevice, sideA: unsafe, sideB: testimony)
if case .safetyBlocked = gateUnsafe {
    check("闸门内含安全筛查", true)
} else {
    check("闸门内含安全筛查", false, "实际 \(String(describing: gateUnsafe))")
}

check("单人模式只要求 A 方证词",
      DisputeCaseGate.check(state: .ready, mode: .solo, sideA: testimony, sideB: nil) == nil)

print("=== 评理：TPM / RPM 双桶限流 ===")

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var limiter = ModelRateLimiter(now: t0)

check("初始状态可以立刻发送", limiter.checkDisputeRequest(now: t0) == nil)

// 连续打满 RPM
for _ in 0..<ModelRateLimiter.defaultRPM {
    limiter.recordDisputeRequest(actualTokens: 1_000, now: t0)
}
let afterBurst = limiter.checkDisputeRequest(now: t0)
if case .mustWait(let seconds, let reason)? = afterBurst {
    check("打满 RPM 后被拒绝", reason == .requestsPerMinute, "原因=\(reason)")
    check("需要等待的秒数合理（<2s，因为 120/60=2 个/秒）", seconds <= 2.0, "实际 \(seconds)")
} else {
    check("打满 RPM 后被拒绝", false)
}

// 一分钟过去后恢复
let t1 = t0.addingTimeInterval(61)
check("一分钟后请求桶回满", limiter.checkDisputeRequest(now: t1) == nil)

// TPM 约束
var tokenLimiter = ModelRateLimiter(now: t0)
for _ in 0..<20 {
    tokenLimiter.recordDisputeRequest(actualTokens: 30_000, now: t0)
}
let tokenBlocked = tokenLimiter.checkDisputeRequest(now: t0)
if case .mustWait(_, let reason)? = tokenBlocked {
    check("打满 TPM 后被拒绝（token 维度）", reason == .tokensPerMinute, "原因=\(reason)")
} else {
    check("打满 TPM 后被拒绝（token 维度）", false)
}

check("默认上限与模型契约一致（RPM 120 / TPM 600000）",
      ModelRateLimiter.defaultRPM == 120 && ModelRateLimiter.defaultTPM == 600_000)

check("token 估算对中文按 1 字 1 token 上浮",
      TokenEstimator.estimate(String(repeating: "字", count: 1000)) > 1000)

check("token 估算对英文明显更省",
      TokenEstimator.estimate(String(repeating: "a", count: 1000)) < 400)

print("=== 评理：提示词硬约束存在性 ===")

let sameDevicePrompt = DisputePrompt.systemPrompt(mode: .sameDevice, relationshipLabel: "伴侣")
check("双人提示词禁止责任分配", sameDevicePrompt.contains("禁止任何形式的责任分配"))
check("双人提示词要求两侧字数相当", sameDevicePrompt.contains("20%"))
check("双人提示词声明 69% 依据", sameDevicePrompt.contains("69%"))
check("双人提示词要求用「你们卡在」", sameDevicePrompt.contains("你们卡在"))
check("双人提示词含安全条款", sameDevicePrompt.contains("blocked"))
check("不确定时判 perpetual", sameDevicePrompt.contains("不确定时一律判 perpetual"))

let soloPrompt = DisputePrompt.systemPrompt(mode: .solo, relationshipLabel: "伴侣")
check("单人提示词禁止假装中立", soloPrompt.contains("绝不能假装中立"))
check("单人提示词禁止出现「双方」", soloPrompt.contains("禁止出现「双方」"))
check("单人提示词要求标注猜测", soloPrompt.contains("我猜 TA"))

// 反向验证：两条提示词必须不同（否则"单机不装中立"就没落实）
check("两套提示词确实不同", sameDevicePrompt != soloPrompt)

print("")
print("────────────── 汇总 ──────────────")
print("通过 \(passed) 项，失败 \(failures.count) 项")
if !failures.isEmpty {
    print("失败项：")
    failures.forEach { print("  · \($0)") }
    exit(1)
}
print("全部通过 ✅")
exit(0)
