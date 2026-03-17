//
//  AIService.swift
//  RelationshipCopilot
//
//  AI分析服务 - 使用SophNet Kimi K2.5模型
//

import Foundation
import SwiftData

/// AI服务错误类型
enum AIServiceError: LocalizedError {
    case networkError
    case invalidResponse
    case analysisFailed
    case quotaExceeded
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .networkError:
            return "网络连接失败，请检查网络设置"
        case .invalidResponse:
            return "服务器响应无效"
        case .analysisFailed:
            return "分析处理失败，请稍后重试"
        case .quotaExceeded:
            return "今日分析次数已用完"
        case .apiError(let message):
            return message
        }
    }
}

/// Chat消息
struct ChatMessage: Codable {
    let role: String
    let content: String
}

/// API请求体
struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
}

/// API响应体
struct ChatResponse: Codable {
    let choices: [Choice]?
    let error: APIError?
    
    struct Choice: Codable {
        let message: Message?
        
        struct Message: Codable {
            let content: String?
        }
    }
    
    struct APIError: Codable {
        let message: String?
    }
}

/// AI服务
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()
    
    // ========== 配置区域 ==========
    private let apiEndpoint = "https://api.sophnet.com/v1/text/chatcompletion_v2"
    private let modelName = "Kimi-K2.5"
    // ==============================
    
    @Published var isAnalyzing: Bool = false
    @Published var lastError: AIServiceError?
    @Published var dailyQuota: Int = 10
    @Published var usedToday: Int = 0
    
    private let userDefaults = UserDefaults.standard
    private let quotaKey = "AIAnalysisDailyQuota"
    private let usedKey = "AIAnalysisUsedToday"
    private let dateKey = "AIAnalysisLastDate"
    
    // 系统提示词
    private let systemPrompt = """
你是一个专业的情感关系分析师，擅长分析情侣、夫妻、家人、朋友之间的对话和互动，给出关系健康度评分和改进建议。

请根据用户提供的对话内容或关系信息，从以下维度进行分析：
1. 沟通质量 - 双方是否有效表达感受和需求
2. 情感连接 - 是否有情感支持和共鸣
3. 冲突处理 - 遇到分歧时如何解决
4. 表达方式 - 语言是否温和、有爱
5. 总体氛围 - 关系是轻松还是紧张

请以JSON格式返回分析结果，字段如下：
{
    "score": 85,  // 0-100的整数，表示关系健康度
    "summary": "简要总结（50字以内）",
    "strengths": ["优点1", "优点2", "优点3"],
    "improvements": ["改进点1", "改进点2"],
    "suggestions": ["具体建议1", "具体建议2"],
    "emotionalTrend": "上升/下降/稳定",
    "communicationQuality": "优秀/良好/一般/需要改善"
}

注意：只返回JSON，不要有其他文字。
"""

    private init() {
        checkAndResetDailyQuota()
    }
    
    // MARK: - Public Methods
    
    /// 分析对话录音（使用真实API）
    func analyzeConversation(recording: RecordingSession, profile: Profile) async throws -> AnalysisResult {
        guard !isAnalyzing else {
            throw AIServiceError.analysisFailed
        }
        
        guard usedToday < dailyQuota else {
            throw AIServiceError.quotaExceeded
        }
        
        isAnalyzing = true
        lastError = nil
        
        defer {
            isAnalyzing = false
        }
        
        do {
            // 使用Kimi K2.5分析
            let result = try await performAIAnalysis(
                conversationText: recording.transcription ?? "无文字记录",
                profileName: profile.name,
                relationshipType: relationshipTypeText(profile.relationshipType)
            )
            usedToday += 1
            saveUsage()
            return result
        } catch let error as AIServiceError {
            lastError = error
            throw error
        } catch {
            lastError = .networkError
            throw AIServiceError.networkError
        }
    }
    
    /// 生成关系健康度报告
    func generateHealthReport(for profile: Profile, sessions: [RecordingSession]) async throws -> AnalysisResult {
        guard !isAnalyzing else {
            throw AIServiceError.analysisFailed
        }
        
        isAnalyzing = true
        
        defer {
            isAnalyzing = false
        }
        
        // 如果有历史记录，使用AI生成综合报告
        if !sessions.isEmpty {
            let combinedText = sessions.prefix(5).compactMap { $0.transcription }.joined(separator: "\n---\n")
            
            if !combinedText.isEmpty {
                return try await performAIAnalysis(
                    conversationText: combinedText,
                    profileName: profile.name,
                    relationshipType: relationshipTypeText(profile.relationshipType)
                )
            }
        }
        
        // 没有足够数据时生成默认报告
        let avgScore = calculateAverageScore(from: sessions)
        return AnalysisResult(
            emotionScore: Double(avgScore),
            communicationPatterns: generateStrengths(profile: profile),
            recommendations: generateSuggestions(profile: profile, score: avgScore),
            summary: generateSummary(score: avgScore, profile: profile),
            keywords: generateImprovements(score: avgScore)
        )
    }
    
    /// 获取智能建议
    func getSuggestions(for profile: Profile) async -> [String] {
        var suggestions: [String] = []
        
        let calendar = Calendar.current
        let now = Date()
        
        switch profile.relationshipType {
        case "partner", "spouse":
            suggestions = [
                "今天可以给对方一个惊喜，表达你的感激之情",
                "一起回忆初次相遇的美好时光",
                "尝试一起完成一个新活动，增加共同回忆"
            ]
        case "family":
            suggestions = [
                "给家人打个电话，关心近况",
                "分享一些生活中的趣事",
                "一起用餐，增进感情"
            ]
        case "friend":
            suggestions = [
                "约出来喝杯咖啡聊聊近况",
                "分享最近看到的有趣内容",
                "在重要日子送上祝福"
            ]
        case "colleague":
            suggestions = [
                "在工作中多给予支持和配合",
                "适当表达感谢和认可"
            ]
        default:
            suggestions = ["保持真诚和尊重的沟通"]
        }
        
        if let birthday = profile.birthday {
            let daysUntilBirthday = calendar.dateComponents([.day], from: now, to: birthday).day ?? 0
            if daysUntilBirthday > 0 && daysUntilBirthday <= 7 {
                suggestions.insert("即将迎来对方的生日，提前准备惊喜吧！", at: 0)
            }
        }
        
        return suggestions
    }
    
    /// 重置每日配额
    func resetDailyQuota() {
        usedToday = 0
        saveUsage()
    }
    
    // MARK: - Private Methods - AI分析
    
    private func performAIAnalysis(conversationText: String, profileName: String, relationshipType: String) async throws -> AnalysisResult {
        // 构建用户prompt
        let userPrompt = """
请分析以下\(relationshipType)关系中的对话内容。

对方姓名：\(profileName)

对话内容：
\(conversationText)

请分析这段对话中双方的关系健康程度，并给出评分和改进建议。
"""
        
        // 构建请求
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = ChatRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            max_tokens: 1500
        )
        
        // 编码请求体
        guard let url = URL(string: apiEndpoint) else {
            throw AIServiceError.invalidResponse
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer ikxSEUNZhZf8DwR9Ey889ZF0n_dElfgJ_bRluP4RB1YTXVKT1M3HAsvoprWtWIwsHLE4kJbp9y-T42ttq9pFFQ", forHTTPHeaderField: "Authorization")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        // 发送请求
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw AIServiceError.apiError("API密钥无效")
            } else if httpResponse.statusCode == 429 {
                throw AIServiceError.quotaExceeded
            }
            throw AIServiceError.apiError("HTTP \(httpResponse.statusCode)")
        }
        
        // 解析响应
        let decoder = JSONDecoder()
        let chatResponse = try decoder.decode(ChatResponse.self, from: data)
        
        guard let content = chatResponse.choices?.first?.message?.content else {
            if let errorMessage = chatResponse.error?.message {
                throw AIServiceError.apiError(errorMessage)
            }
            throw AIServiceError.invalidResponse
        }
        
        // 解析JSON结果
        return try parseAnalysisResult(content)
    }
    
    private func parseAnalysisResult(_ jsonString: String) throws -> AnalysisResult {
        // 尝试提取JSON部分
        var cleanJson = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 移除可能的markdown代码块
        if cleanJson.hasPrefix("```json") {
            cleanJson = String(cleanJson.dropFirst(7))
        }
        if cleanJson.hasPrefix("```") {
            cleanJson = String(cleanJson.dropFirst(3))
        }
        if cleanJson.hasSuffix("```") {
            cleanJson = String(cleanJson.dropLast(3))
        }
        cleanJson = cleanJson.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = cleanJson.data(using: .utf8) else {
            throw AIServiceError.invalidResponse
        }
        
        // 自定义解析，兼容不同字段名
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let score = json["score"] as? Int ?? 75
            let summary = json["summary"] as? String ?? ""
            let strengths = json["strengths"] as? [String] ?? []
            let improvements = json["improvements"] as? [String] ?? []
            let suggestions = json["suggestions"] as? [String] ?? []
            let emotionalTrend = json["emotionalTrend"] as? String ?? "稳定"
            let communicationQuality = json["communicationQuality"] as? String ?? "良好"
            
            return AnalysisResult(
                emotionScore: Double(score),
                communicationPatterns: strengths,
                recommendations: suggestions,
                summary: summary,
                keywords: improvements
            )
        }
        
        throw AIServiceError.invalidResponse
    }
    
    // MARK: - Private Methods - 备用逻辑
    
    private func calculateAverageScore(from sessions: [RecordingSession]) -> Int {
        guard !sessions.isEmpty else { return 75 }
        
        let total = sessions.reduce(0) { $0 + Int($1.analysisResult?.emotionScore ?? 75) }
        return min(100, max(0, total / sessions.count))
    }
    
    private func relationshipTypeText(_ type: String) -> String {
        switch type {
        case "partner": return "伴侣"
        case "spouse": return "配偶"
        case "family": return "家人"
        case "friend": return "朋友"
        case "colleague": return "同事"
        default: return "其他"
        }
    }
    
    private func generateSummary(score: Int, profile: Profile) -> String {
        let relationshipWord = relationshipTypeText(profile.relationshipType)
        
        if score >= 85 {
            return "与\(profile.name)的\(relationshipWord)关系非常健康。"
        } else if score >= 70 {
            return "与\(profile.name)的\(relationshipWord)关系总体良好。"
        } else if score >= 60 {
            return "与\(profile.name)的\(relationshipWord)关系需要更多关注。"
        } else {
            return "与\(profile.name)的\(relationshipWord)关系需要改善。"
        }
    }
    
    private func generateStrengths(profile: Profile) -> [String] {
        switch profile.relationshipType {
        case "partner", "spouse":
            return ["相互尊重", "愿意付出", "沟通理性"]
        case "family":
            return ["天然信任", "相互支持"]
        case "friend":
            return ["真诚相待", "志趣相投"]
        case "colleague":
            return ["专业配合", "相互尊重"]
        default:
            return ["保持真诚"]
        }
    }
    
    private func generateImprovements(score: Int) -> [String] {
        if score >= 70 {
            return ["增加日常互动", "多表达感激"]
        } else {
            return ["建立稳定沟通", "学会倾听", "增加相处时间"]
        }
    }
    
    private func generateSuggestions(profile: Profile, score: Int) -> [String] {
        var suggestions: [String] = []
        
        if score < 70 {
            suggestions.append("安排一次深入交流，坦诚分享感受")
        }
        
        if profile.relationshipType == "partner" || profile.relationshipType == "spouse" {
            suggestions.append("可以一起看部电影或共进晚餐")
        }
        
        suggestions.append("在重要日子给予特别关注")
        return suggestions
    }
    
    // MARK: - Quota Management
    
    private func checkAndResetDailyQuota() {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastDate = userDefaults.object(forKey: dateKey) as? Date {
            let lastDay = Calendar.current.startOfDay(for: lastDate)
            if lastDay < today {
                usedToday = 0
            } else {
                usedToday = userDefaults.integer(forKey: usedKey)
            }
        }
        dailyQuota = 10
    }
    
    private func saveUsage() {
        userDefaults.set(usedToday, forKey: usedKey)
        userDefaults.set(Date(), forKey: dateKey)
    }
}