//
//  RateLimiter.swift
//  RelationshipCopilot
//
//  模型 API 的速率约束。**这是配额层的关键新增**。
//
//  背景：模型服务端有硬限制 TPM（每分钟 token 数）与 RPM（每分钟请求数）。
//  超出后不是"变慢"，是直接 **429 → 任务被终止**。
//  客户端如果只按"每天 N 次"计数，一次密集重试就能把 429 打出来。
//
//  实现：**令牌桶（token bucket）**，双桶同时约束：
//   - 请求桶：RPM 120  → 每 500ms 补一个令牌，容量 120
//   - 字数桶：TPM 600000（按 token 估算）→ 按秒匀速回填，容量为上限
//
//  为什么用令牌桶而不是固定窗口计数器：
//  固定窗口在窗口边界会允许 2 倍突发（59.9s 用满 + 60.1s 再用满），
//  这正是打出 429 的典型姿势。令牌桶的容量就是硬上限，边界无突发。
//
//  纯函数 + 注入时钟，可直接单测（见 Tests/LogicTests.swift）。
//

import Foundation

/// 估算 token 用量。
///
/// 中日韩字符约 1 token / 字；拉丁文本约 1 token / 4 字符。
/// 提示词与输出都按此估算，并**主动上浮 15%** 作为安全边际 ——
/// 宁可少发一次请求，也不要撞 429 把整个任务打死。
enum TokenEstimator {

    /// 安全边际系数。
    static let safetyMargin: Double = 1.15

    static func estimate(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF,     // CJK 统一汉字
                 0x3400...0x4DBF,     // 扩展 A
                 0x3040...0x30FF,     // 日文假名
                 0xAC00...0xD7AF,     // 韩文
                 0x3000...0x303F,     // CJK 标点
                 0xFF00...0xFFEF:     // 全角
                cjk += 1
            default:
                other += 1
            }
        }
        let raw = Double(cjk) + Double(other) / 4.0
        return Int((raw * safetyMargin).rounded(.up))
    }

    /// 一次评理请求的预估总量（输入 + 输出）。
    /// 用于在发请求**之前**判断桶里够不够，避免发出去才被拒。
    static func estimateDisputeRequest(
        systemPrompt: String,
        testimonyA: String,
        testimonyB: String,
        maxOutputTokens: Int
    ) -> Int {
        estimate(systemPrompt) + estimate(testimonyA) + estimate(testimonyB) + maxOutputTokens
    }
}

// MARK: - 限流错误

enum RateLimitError: LocalizedError, Equatable {
    /// 当前无法立即发送，需要等待若干秒。
    case mustWait(seconds: Double, reason: Reason)

    enum Reason: String, Sendable {
        case requestsPerMinute
        case tokensPerMinute
    }

    var errorDescription: String? {
        switch self {
        case .mustWait(let seconds, let reason):
            let rounded = max(1, Int(seconds.rounded(.up)))
            switch reason {
            case .requestsPerMinute:
                return "请求过于频繁，请等 \(rounded) 秒再试。"
            case .tokensPerMinute:
                return "本分钟的内容量已接近上限，请等 \(rounded) 秒再试。"
            }
        }
    }
}

// MARK: - 令牌桶

/// 单个令牌桶。
struct TokenBucket: Equatable, Sendable {

    /// 桶容量 = 硬上限。超过即拒绝。
    let capacity: Double
    /// 每秒回填量 = 上限 / 60。
    let refillPerSecond: Double

    private(set) var tokens: Double
    private(set) var lastRefill: Date

    init(capacity: Double, refillPerSecond: Double, now: Date) {
        self.capacity = max(1, capacity)
        self.refillPerSecond = max(0, refillPerSecond)
        self.tokens = self.capacity
        self.lastRefill = now
    }

    /// 按经过时间回填（不超过容量）。
    mutating func refill(now: Date) {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
    }

    /// 当前可用的整数量。
    var available: Int { Int(tokens.rounded(.down)) }

    /// 需要等待多久才能攒够 `amount`。已够则返回 0。
    func waitTime(for amount: Double) -> Double {
        guard amount > tokens else { return 0 }
        guard refillPerSecond > 0 else { return .infinity }
        return (amount - tokens) / refillPerSecond
    }

    /// 扣减。调用前必须先用 `waitTime` 确认够用。
    mutating func consume(_ amount: Double) {
        tokens = max(0, tokens - amount)
    }
}

// MARK: - 双桶限流器

/// 同时约束 RPM 与 TPM。
///
/// 两个桶任一不足即拒绝 —— 这是**与**关系，不是或。
struct ModelRateLimiter: Sendable {

    /// 每分钟请求数上限。
    let requestsPerMinute: Int
    /// 每分钟 token 上限。
    let tokensPerMinute: Int

    private(set) var requestBucket: TokenBucket
    private(set) var tokenBucket: TokenBucket

    init(
        requestsPerMinute: Int = ModelRateLimiter.defaultRPM,
        tokensPerMinute: Int = ModelRateLimiter.defaultTPM,
        now: Date = Date()
    ) {
        self.requestsPerMinute = max(1, requestsPerMinute)
        self.tokensPerMinute = max(1, tokensPerMinute)
        self.requestBucket = TokenBucket(
            capacity: Double(self.requestsPerMinute),
            refillPerSecond: Double(self.requestsPerMinute) / 60.0,
            now: now
        )
        self.tokenBucket = TokenBucket(
            capacity: Double(self.tokensPerMinute),
            refillPerSecond: Double(self.tokensPerMinute) / 60.0,
            now: now
        )
    }

    /// 默认配额。与模型服务端的实际限制一致。
    static let defaultRPM = 120
    static let defaultTPM = 600_000

    /// 保守值：单次请求的 token 预留。
    /// 评理请求输入约 1.5k、输出上限 1.2k，取 3k 留足余量。
    static let reservedTokensPerDispute = 3_000

    // MARK: 判定

    /// 当前是否可立即发送一次评理请求。不足时返回需要等待的秒数。
    mutating func checkDisputeRequest(now: Date = Date()) -> RateLimitError? {
        requestBucket.refill(now: now)
        tokenBucket.refill(now: now)

        let waitRequests = requestBucket.waitTime(for: 1)
        if waitRequests > 0 {
            return .mustWait(seconds: waitRequests, reason: .requestsPerMinute)
        }

        let waitTokens = tokenBucket.waitTime(for: Double(Self.reservedTokensPerDispute))
        if waitTokens > 0 {
            return .mustWait(seconds: waitTokens, reason: .tokensPerMinute)
        }
        return nil
    }

    /// 记录一次已发出的请求。必须在**请求成功后**调用，
    /// 失败（网络错误）不扣，因为服务端通常也不计费失败请求。
    mutating func recordDisputeRequest(actualTokens: Int? = nil, now: Date = Date()) {
        requestBucket.refill(now: now)
        tokenBucket.refill(now: now)
        requestBucket.consume(1)
        let cost = Double(actualTokens ?? Self.reservedTokensPerDispute)
        tokenBucket.consume(min(cost, Double(tokensPerMinute)))
    }

    // MARK: 展示

    /// 供设置页展示的诊断文本。
    func diagnostics(now: Date = Date()) -> String {
        var copy = self
        copy.requestBucket.refill(now: now)
        copy.tokenBucket.refill(now: now)
        return "请求 \(copy.requestBucket.available)/\(requestsPerMinute) 次 · 内容量 \(copy.tokenBucket.available)/\(tokensPerMinute)"
    }
}
