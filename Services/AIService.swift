//
//  AIService.swift
//  RelationshipCopilot
//
//  AI 分析服务。
//
//  修复报告 A2 / A6 / D1 / D2 / B7：
//   - D1（P0）：移除 `AIService.swift:277` 里明文硬编码的 SophNet 密钥。客户端不再持有第三方密钥，
//              改由 `EndpointConfiguration` 解析「自有代理」或「调试直连（Keychain 取密钥）」。
//   - D2：配额在**所有**分析入口统一校验与扣减（原 `generateHealthReport` 完全不检查）；
//         解析失败不再编造 75 分（原 `parseAnalysisResult` 用 `?? 75`）。
//   - A2：抽出 `ConversationAnalyzing` 协议，View 依赖协议而非单例，便于预览与测试注入。
//   - B7：请求加超时与有限重试；网络错误归一化为 `AppError`。
//
//  诚实边界：当前仓库没有后端。`proxy` 模式需要在服务端实现本文件注释里约定的接口；
//  未配置时 `analyze` 会抛 `.aiNotConfigured`，UI 明确提示，而不是返回假结果。
//

import Foundation

// MARK: - 协议

/// 对话分析能力。View 层依赖此协议，便于注入 Mock。
protocol ConversationAnalyzing: Sendable {
    /// 分析一段对话文本。
    func analyze(
        conversation: String,
        counterpartName: String,
        relationshipType: RelationshipType
    ) async throws -> AnalysisResult
}

// MARK: - 请求/响应线格式

/// 自有代理的请求体。
/// 服务端约定：`POST {base}/v1/relationship/analyze`
/// 请求 `{ "conversation": "...", "counterpartName": "...", "relationshipType": "partner" }`
/// 响应：优先接受 `{ "analysis": { score, summary, strengths, improvements, suggestions,
///                                  emotionalTrend, communicationQuality } }`，
///      也兼容 OpenAI Chat Completions 形态（`choices[0].message.content` 内含同一 JSON）。
private struct ProxyAnalyzeRequest: Encodable {
    let conversation: String
    let counterpartName: String
    let relationshipType: String
}

/// 直连形态的 Chat Completions 请求体（仅调试用）。
private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        /// `"stop"` 表示正常结束；`"length"` 表示撞上 `max_tokens` 被截断。
        ///
        /// **必须解析这一栏。** 推理模型（如 DeepSeek-V4.1-Flash）会把
        /// `reasoning_content` 计入 `max_tokens`，正文可能只剩一点点，
        /// JSON 就被截在半句话上。以前这里不读 `finish_reason`，
        /// 于是截断只能表现为"JSON 解析失败"，诊断信息是笼统的"格式漂移"——
        /// 排查时根本想不到是预算不够。
        let finish_reason: String?
    }
    struct APIError: Decodable { let message: String? }
    let choices: [Choice]?
    let error: APIError?
}

private struct ProxyEnvelope: Decodable {
    let analysis: ProxyAnalysisPayload?
    let choices: [ChatCompletionResponse.Choice]?
    let error: ChatCompletionResponse.APIError?
}

/// 快速工具的代理请求/响应（`POST {base}/v1/assist`）。
private struct AssistRequest: Encodable {
    let tool: String
    let input: String
}

/// 评理的代理请求（`POST {base}/v1/dispute/evaluate`）。
/// 服务端约定：原样把 systemPrompt / userMessage 转给模型，回传模型原始文本（含 JSON）。
private struct DisputeProxyRequest: Encodable {
    let systemPrompt: String
    let userMessage: String
    let temperature: Double
    let maxTokens: Int

    init(systemPrompt: String, userMessage: String) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.temperature = DisputePrompt.temperature
        self.maxTokens = DisputePrompt.maxOutputTokens
    }
}

private struct AssistEnvelope: Decodable {
    let text: String?
    let choices: [ChatCompletionResponse.Choice]?
    let error: ChatCompletionResponse.APIError?
}

private struct ProxyAnalysisPayload: Decodable {
    let score: Int?
    let summary: String?
    let strengths: [String]?
    let improvements: [String]?
    let suggestions: [String]?
    let emotionalTrend: String?
    let communicationQuality: String?
}

// MARK: - 服务

@MainActor
@Observable
final class AIService: ConversationAnalyzing, DisputeEvaluating {

    static let shared = AIService()

    // MARK: 状态

    private(set) var isAnalyzing = false
    var lastError: AppError?

    private(set) var dailyLimit: Int
    private(set) var usedToday: Int
    private(set) var modeDescription: String

    // MARK: 依赖

    private let keychain: SecureStoring
    private let defaults: UserDefaults
    private let session: URLSession
    private let mode: AIEndpointMode

    private enum Keys {
        static let used = "AIAnalysisUsedToday"
        static let lastDay = "AIAnalysisLastResetDay"
    }

    /// 直连时使用的模型名（仅调试模式走这条路径）。
    ///
    /// 从 Info.plist 的 `RCDirectModelName` 读取，而不是写死在代码里：
    /// 模型迭代很快，写死意味着换模型要改代码、重新编译、重新分发。
    private let directModelName: String

    /// 代理模式的共享令牌，存在 Keychain。
    ///
    /// 它不是"身份认证"，只是挡住"拿到地址就能白嫖额度"。
    /// 密钥放在客户端理论上可被逆向提取，所以真正的配额控制最终必须在服务端做 ——
    /// 内测阶段用它省掉一次滥用就够。
    ///
    /// 读不到时返回 nil，请求会照发（服务端会回 401）。
    /// 这里**不**因为缺令牌就提前抛错：那样错误会显示成"AI 未配置"，
    /// 而真正的原因是"配了代理但忘了写令牌"，两者排查方向完全不同。
    ///
    /// ## 为什么每次请求都重读，而不是 init 时缓存
    ///
    /// 它原来是 `let`，只在 `init` 里读一次。而设置页允许内测用户**运行时**
    /// 粘贴令牌 —— 那条路径写进 Keychain 后，`AIService.shared` 早已构造完毕，
    /// 手里的 `proxyToken` 永远是 nil。
    ///
    /// 表现：用户填了正确的令牌、看到「已保存」，然后每一次请求都是 401。
    /// 而且重进设置页会显示"已保存"，看起来一切正常。唯一解法是杀掉 App 重开 ——
    /// 一个没人会想到的解法。
    ///
    /// Keychain 读取是毫秒级的内存操作（不是磁盘 IO），每次读没有成本。
    private var proxyToken: String? {
        try? keychain.retrieve(key: EndpointConfiguration.proxyTokenKeychainAccount)
    }

    static let proxyTokenHeader = "x-app-token"

    init(
        keychain: SecureStoring = SecureStorageService.shared,
        defaults: UserDefaults = .standard,
        session: URLSession? = nil,
        mode: AIEndpointMode? = nil,
        dailyLimit: Int = 10
    ) {
        self.keychain = keychain
        self.defaults = defaults
        self.mode = mode ?? EndpointConfiguration.resolve(keychain: keychain)
        self.directModelName = EndpointConfiguration.directModel()
        self.dailyLimit = dailyLimit
        self.modeDescription = EndpointConfiguration.diagnostics(for: self.mode)

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }

        self.usedToday = 0
        checkAndResetDailyQuota()
    }

    // MARK: 对外能力

    var quotaPolicy: QuotaPolicy { QuotaPolicy(limit: dailyLimit) }
    var remainingQuota: Int { quotaPolicy.remaining(used: usedToday) }
    var isConfigured: Bool { mode.isAvailable }

    /// 分析一段对话。所有入口都必须经过这里，以保证配额口径一致。
    func analyze(
        conversation: String,
        counterpartName: String,
        relationshipType: RelationshipType
    ) async throws -> AnalysisResult {
        guard !isAnalyzing else { throw AppError.busy }
        guard !conversation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.emptyTranscription
        }
        guard mode.isAvailable else { throw AppError.aiNotConfigured }
        guard !quotaPolicy.isExhausted(used: usedToday) else { throw AppError.quotaExceeded }

        isAnalyzing = true
        lastError = nil
        defer { isAnalyzing = false }

        do {
            let parsed = try await performRequest(
                conversation: conversation,
                counterpartName: counterpartName,
                relationshipType: relationshipType
            )
            consumeQuota()
            return AnalysisResult(parsed: parsed)
        } catch let error as AppError {
            lastError = error
            throw error
        } catch let error as AIResponseParserError {
            let mapped = AppError.malformedAIResponse(error.localizedDescription)
            lastError = mapped
            throw mapped
        } catch {
            let mapped = AppError.fromNetwork(error)
            lastError = mapped
            throw mapped
        }
    }

    // ## 已删除：`generateHealthReport(for:sessions:)` 与 `resetDailyQuota()`
    //
    // 两个都是全仓库零调用的死代码，删掉共约 26 行。
    //
    // `generateHealthReport` 值得一提：它的 doc 注释写着
    // 「原实现完全不校验配额，是绕过限制的后门；现在与 analyze 共用同一配额」。
    // 这句话描述的是一个**已经不存在的问题** —— 留着它，后来者会以为
    // 这个后门还在，或者以为这个方法还在被调用、还在承担配额守门职责。
    // 实际上所有分析入口（`analyze` / `quickTool` / `evaluate`）都各自
    // 直接做了配额校验，不经过这里。
    //
    // `resetDailyQuota` 是唯一能手动清零当日配额的方法。删它的判断依据：
    // 配额跨天会自动重置（`checkAndResetDailyQuota`），服务端另有独立的
    // 每日限流兜底，所以不存在"配额永久卡死"的死锁。若将来要在设置页
    // 加一个内测用的重置开关，把它加回来只需三行（清零 + `persistQuota()`）。

    // MARK: - 评理（第三方之见）
    //
    // 与 analyze / quickTool 的区别：
    //   - 评理有**双桶限流**（RPM 120 / TPM 600000）。超限不是"变慢"，是 429 直接终止任务，
    //     所以发请求前先在本地桶里预检，不够就返回 `.rateLimited` 让用户等几秒。
    //   - 安全筛查在**调用模型之前**跑。命中即返回 .blocked，一个 token 都不花。
    //   - 解析失败不编造结果，降级为原话摘录（`.fallback`）。

    /// 本地速率桶。跨调用累积，随 App 进程生命周期存在。
    private var rateLimiter = ModelRateLimiter()

    /// 最近一次评理的速率诊断（设置页展示用）。
    var rateLimitDiagnostics: String {
        rateLimiter.diagnostics()
    }

    func evaluate(_ request: DisputeRequest) async throws -> DisputeOutcome {
        guard !isAnalyzing else { throw AppError.busy }

        // ① 安全前置：命中即拒绝评理，不调用模型
        let screeningA = SafetyScreen.screen(request.sideA)
        if screeningA.isBlocking {
            AppLog.ai.notice("Dispute blocked locally (A): \(screeningA.concerns.map(\.rawValue).joined(separator: ","), privacy: .public)")
            return .blocked(SafetyScreen.guidance(for: screeningA.concerns))
        }
        if let sideB = request.sideB {
            let screeningB = SafetyScreen.screen(sideB)
            if screeningB.isBlocking {
                AppLog.ai.notice("Dispute blocked locally (B): \(screeningB.concerns.map(\.rawValue).joined(separator: ","), privacy: .public)")
                return .blocked(SafetyScreen.guidance(for: screeningB.concerns))
            }
        }

        guard mode.isAvailable else { throw AppError.aiNotConfigured }
        guard !quotaPolicy.isExhausted(used: usedToday) else { throw AppError.quotaExceeded }

        // ② 速率预检：本地桶不够就明确告知要等几秒，而不是发出去撞 429
        if let limitError = rateLimiter.checkDisputeRequest() {
            throw AppError.rateLimited(limitError.localizedDescription)
        }

        isAnalyzing = true
        lastError = nil
        defer { isAnalyzing = false }

        let systemPrompt = DisputePrompt.systemPrompt(
            mode: request.mode,
            relationshipLabel: request.relationshipLabel
        )
        let userMessage: String
        switch request.mode {
        case .sameDevice, .remote:
            // gate 已保证 sideB 非 nil；这里仍做兜底，避免坐标外调用泄露单方数据
            guard let sideB = request.sideB else { throw AppError.malformedAIResponse("缺少第二份证词") }
            userMessage = DisputePrompt.sameDeviceUserMessage(a: request.sideA, b: sideB)
        case .solo:
            userMessage = DisputePrompt.soloUserMessage(request.sideA)
        }

        let actualTokens = TokenEstimator.estimateDisputeRequest(
            systemPrompt: systemPrompt,
            testimonyA: userMessage,
            testimonyB: "",
            maxOutputTokens: DisputePrompt.maxOutputTokens
        )

        do {
            let raw = try await performDisputeRequest(systemPrompt: systemPrompt, userMessage: userMessage)

            // 请求成功才扣桶（服务端对失败请求通常也不计费）
            rateLimiter.recordDisputeRequest(actualTokens: actualTokens)
            consumeQuota()

            do {
                let verdict = try DisputeVerdictParser.parse(raw)
                return .verdict(verdict)
            } catch let parseError as DisputeVerdictParserError {
                // 模型侧安全拒答 → 当安全拦截处理，不给降级结果
                if case .safetyBlocked = parseError {
                    let concerns = SafetyScreen.screen(raw).concerns
                    let effective = concerns.isEmpty ? SafetyConcern.allCases : concerns
                    return .blocked(SafetyScreen.guidance(for: effective))
                }

                // 其余解析失败：重试一次（格式漂移是最常见原因），仍失败则降级
                AppLog.ai.warning("Dispute parse failed, retrying once: \(parseError.localizedDescription, privacy: .public)")
                let retryRaw = try? await performDisputeRequest(systemPrompt: systemPrompt, userMessage: userMessage)
                if let retryRaw,
                   let retried = try? DisputeVerdictParser.parse(retryRaw) {
                    return .verdict(retried)
                }

                // 降级：不编造评理，只对称摘录双方原话
                let fallback = DisputeVerdictParser.fallback(
                    a: request.sideA,
                    b: request.sideB ?? request.sideA,
                    reason: parseError.localizedDescription
                )
                return .fallback(fallback, reason: parseError.localizedDescription)
            }
        } catch let error as AppError {
            lastError = error
            throw error
        } catch {
            let mapped = AppError.fromNetwork(error)
            lastError = mapped
            throw mapped
        }
    }

    private func performDisputeRequest(systemPrompt: String, userMessage: String) async throws -> String {
        switch mode {
        case .unconfigured:
            throw AppError.aiNotConfigured

        case .proxy(let baseURL):
            var request = URLRequest(url: baseURL.appending(path: "v1/dispute/evaluate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                DisputeProxyRequest(systemPrompt: systemPrompt, userMessage: userMessage)
            )
            let (data, response) = try await send(request)
            try validate(response: response)

            if let envelope = try? JSONDecoder().decode(AssistEnvelope.self, from: data) {
                if let text = envelope.text, !text.isEmpty { return text }
                if let content = envelope.choices?.first?.message?.content, !content.isEmpty { return content }
                if let message = envelope.error?.message { throw AppError.malformedAIResponse(message) }
            }
            throw AppError.malformedAIResponse("响应结构无法识别")

        case .direct(let baseURL, let apiKey):
            var request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body = ChatCompletionRequest(
                model: directModelName,
                messages: [
                    ChatMessage(role: "system", content: systemPrompt),
                    ChatMessage(role: "user", content: userMessage)
                ],
                temperature: DisputePrompt.temperature,
                max_tokens: DisputePrompt.maxOutputTokens
            )
            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await send(request)
            try validate(response: response)
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let choice = decoded.choices?.first else {
                if let message = decoded.error?.message { throw AppError.malformedAIResponse(message) }
                throw AppError.malformedAIResponse("响应缺少 choices")
            }
            guard let content = choice.message?.content, !content.isEmpty else {
                if let message = decoded.error?.message { throw AppError.malformedAIResponse(message) }
                // 空正文且被截断，几乎一定是 reasoning 吃光了预算
                if choice.finish_reason == "length" {
                    throw AppError.malformedAIResponse("模型思考过程用尽了输出预算，正文为空")
                }
                throw AppError.malformedAIResponse("响应缺少 content")
            }
            // 截断的 JSON 必然解析失败，但**失败的表述必须指向真实原因**。
            // 说"格式漂移"会让人去查提示词，而真正的修法是提高 max_tokens。
            if choice.finish_reason == "length" {
                throw AppError.malformedAIResponse("模型输出被长度上限截断（正文 \(content.count) 字）")
            }
            return content
        }
    }

    // MARK: 请求实现

    /// 快速工具生成（吵架复盘 / 话术急救 / 道歉生成 / 关系体检）。
    /// 修复报告 E2：这些工具原先全部返回硬编码模板，与用户输入几乎无关。
    func quickTool(kind: QuickToolKind, input: String) async throws -> String {
        guard !isAnalyzing else { throw AppError.busy }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.emptyTranscription
        }
        guard mode.isAvailable else { throw AppError.aiNotConfigured }
        guard !quotaPolicy.isExhausted(used: usedToday) else { throw AppError.quotaExceeded }

        isAnalyzing = true
        lastError = nil
        defer { isAnalyzing = false }

        do {
            let text = try await performAssist(kind: kind, input: input)
            consumeQuota()
            return text
        } catch let error as AppError {
            lastError = error
            throw error
        } catch {
            let mapped = AppError.fromNetwork(error)
            lastError = mapped
            throw mapped
        }
    }

    private func performAssist(kind: QuickToolKind, input: String) async throws -> String {        switch mode {
        case .unconfigured:
            throw AppError.aiNotConfigured

        case .proxy(let baseURL):
            var request = URLRequest(url: baseURL.appending(path: "v1/assist"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                AssistRequest(tool: kind.rawValue, input: input)
            )
            let (data, response) = try await send(request)
            try validate(response: response)

            if let envelope = try? JSONDecoder().decode(AssistEnvelope.self, from: data) {
                if let text = envelope.text, !text.isEmpty { return text }
                if let content = envelope.choices?.first?.message?.content, !content.isEmpty {
                    return content
                }
                if let message = envelope.error?.message {
                    throw AppError.malformedAIResponse(message)
                }
            }
            throw AppError.malformedAIResponse("响应结构无法识别")

        case .direct(let baseURL, let apiKey):
            var request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body = ChatCompletionRequest(
                model: directModelName,
                messages: [
                    ChatMessage(role: "system", content: kind.systemPrompt),
                    ChatMessage(role: "user", content: input)
                ],
                temperature: 0.5,
                max_tokens: 900
            )
            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await send(request)
            try validate(response: response)
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let content = decoded.choices?.first?.message?.content, !content.isEmpty else {
                if let message = decoded.error?.message {
                    throw AppError.malformedAIResponse(message)
                }
                throw AppError.malformedAIResponse("响应缺少 content")
            }
            return content
        }
    }

    private func performRequest(
        conversation: String,
        counterpartName: String,
        relationshipType: RelationshipType
    ) async throws -> ParsedAnalysis {
        switch mode {
        case .proxy(let baseURL):
            return try await performProxyRequest(
                baseURL: baseURL,
                conversation: conversation,
                counterpartName: counterpartName,
                relationshipType: relationshipType
            )
        case .direct(let baseURL, let apiKey):
            return try await performDirectRequest(
                baseURL: baseURL,
                apiKey: apiKey,
                conversation: conversation,
                counterpartName: counterpartName,
                relationshipType: relationshipType
            )
        case .unconfigured:
            throw AppError.aiNotConfigured
        }
    }

    private func performProxyRequest(
        baseURL: URL,
        conversation: String,
        counterpartName: String,
        relationshipType: RelationshipType
    ) async throws -> ParsedAnalysis {
        var request = URLRequest(url: baseURL.appending(path: "v1/relationship/analyze"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ProxyAnalyzeRequest(
                conversation: conversation,
                counterpartName: counterpartName,
                relationshipType: relationshipType.rawValue
            )
        )

        let (data, response) = try await send(request)
        try validate(response: response)

        let decoder = JSONDecoder()
        let envelope = try? decoder.decode(ProxyEnvelope.self, from: data)

        if let payload = envelope?.analysis {
            let parsed = ParsedAnalysis(
                score: payload.score,
                summary: payload.summary,
                strengths: payload.strengths ?? [],
                improvements: payload.improvements ?? [],
                suggestions: payload.suggestions ?? [],
                emotionalTrend: payload.emotionalTrend,
                communicationQuality: payload.communicationQuality
            )
            guard parsed.hasUsableContent else { throw AppError.malformedAIResponse("字段为空") }
            return parsed
        }

        // 兼容 OpenAI Chat Completions 形态
        if let content = envelope?.choices?.first?.message?.content {
            return try AIResponseParser.parse(content)
        }
        if let message = envelope?.error?.message {
            throw AppError.malformedAIResponse(message)
        }
        throw AppError.malformedAIResponse("响应结构无法识别")
    }

    private func performDirectRequest(
        baseURL: URL,
        apiKey: String,
        conversation: String,
        counterpartName: String,
        relationshipType: RelationshipType
    ) async throws -> ParsedAnalysis {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 密钥来自 Keychain（开发者手动写入），源码中不存在任何字面量
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionRequest(
            model: directModelName,
            messages: [
                ChatMessage(role: "system", content: Self.systemPrompt),
                ChatMessage(
                    role: "user",
                    content: """
                    请分析以下\(relationshipType.displayName)关系中的对话内容。
                    对方姓名：\(counterpartName)
                    对话内容：
                    \(conversation)
                    """
                )
            ],
            // 报告 N1 的验证要求：同一段对话重复分析应给出语义一致的结果，
            // 因此把 temperature 从 0.7 降到 0.4。
            temperature: 0.4,
            max_tokens: 1200
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        try validate(response: response)

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices?.first?.message?.content else {
            if let message = decoded.error?.message {
                throw AppError.malformedAIResponse(message)
            }
            throw AppError.malformedAIResponse("响应缺少 content")
        }
        return try AIResponseParser.parse(content)
    }

    /// 发送请求，对超时与瞬时网络错误做一次重试。
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // 代理模式下统一补上共享令牌。
        //
        // 放在这一个地方而不是每个 case 里各写一遍：三处代理请求各写一次的话，
        // 以后新增端点必然漏写一处，而漏掉的表现是 401「未授权」——
        // 看起来像服务端坏了，其实是客户端少了个头。
        //
        // 直连模式不需要：那条路用的是 `Authorization: Bearer <模型厂商密钥>`。
        var request = request
        if case .proxy = mode, request.value(forHTTPHeaderField: Self.proxyTokenHeader) == nil {
            if let token = proxyToken, !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: Self.proxyTokenHeader)
            }
        }

        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            AppLog.ai.warning("Retrying after \(error.code.rawValue, privacy: .public)")
            try await Task.sleep(nanoseconds: 600_000_000)
            return try await session.data(for: request)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverError(-1)
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw AppError.unauthorized
        case 429:
            throw AppError.quotaExceeded
        default:
            throw AppError.serverError(http.statusCode)
        }
    }

    // MARK: 配额

    private func checkAndResetDailyQuota() {
        let today = Calendar.current.startOfDay(for: Date())
        let last = defaults.object(forKey: Keys.lastDay) as? Date
        if QuotaPolicy.shouldReset(lastResetDay: last, today: today) {
            usedToday = 0
            persistQuota()
        } else {
            usedToday = max(0, defaults.integer(forKey: Keys.used))
        }
    }

    private func consumeQuota() {
        usedToday += 1
        persistQuota()
    }

    private func persistQuota() {
        defaults.set(usedToday, forKey: Keys.used)
        defaults.set(Calendar.current.startOfDay(for: Date()), forKey: Keys.lastDay)
    }

    // MARK: 提示词

    private static let systemPrompt = """
    你是一个专业的情感关系分析师，擅长分析情侣、夫妻、家人、朋友之间的对话和互动，给出关系健康度评分和改进建议。

    请根据用户提供的对话内容或关系信息，从以下维度进行分析：
    1. 沟通质量 - 双方是否有效表达感受和需求
    2. 情感连接 - 是否有情感支持和共鸣
    3. 冲突处理 - 遇到分歧时如何解决
    4. 表达方式 - 语言是否温和、有爱
    5. 总体氛围 - 关系是轻松还是紧张

    请以 JSON 格式返回分析结果，字段如下：
    {
        "score": 85,
        "summary": "简要总结（50字以内）",
        "strengths": ["优点1", "优点2"],
        "improvements": ["改进点1", "改进点2"],
        "suggestions": ["具体建议1", "具体建议2"],
        "emotionalTrend": "上升/下降/稳定",
        "communicationQuality": "优秀/良好/一般/需要改善"
    }

    注意：
    - score 为 0-100 的整数，必须基于对话内容判断；如果对话内容不足以判断，请省略 score 字段而不是编造。
    - 只返回 JSON，不要有其他文字。
    """
}
