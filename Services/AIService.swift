//
//  AIService.swift
//  RelationshipCopilot
//
//  AI分析服务 - 提供关系分析、智能建议等功能
//

import Foundation
import SwiftData

/// AI服务错误类型
enum AIServiceError: LocalizedError {
    case networkError
    case invalidResponse
    case analysisFailed
    case quotaExceeded
    
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
        }
    }
}

/// 分析结果
struct AnalysisResult: Codable {
    let score: Int  // 0-100
    let summary: String
    let strengths: [String]
    let improvements: [String]
    let suggestions: [String]
    let emotionalTrend: String
    let communicationQuality: String
    let nextReviewDate: Date
}

/// 情感趋势数据
struct EmotionalTrend: Codable {
    let date: Date
    let score: Int
    let event: String?
}

/// AI服务
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()
    
    @Published var isAnalyzing: Bool = false
    @Published var lastError: AIServiceError?
    @Published var dailyQuota: Int = 3
    @Published var usedToday: Int = 0
    
    private let apiEndpoint = "https://api.sophnet.com/v1/analysis"
    private let userDefaults = UserDefaults.standard
    private let quotaKey = "AIAnalysisDailyQuota"
    private let usedKey = "AIAnalysisUsedToday"
    private let dateKey = "AIAnalysisLastDate"
    
    private init() {
        checkAndResetDailyQuota()
    }
    
    // MARK: - Public Methods
    
    /// 分析对话录音
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
            // 模拟API调用（实际项目中替换为真实API）
            let result = try await performAnalysis(recording: recording, profile: profile)
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
        
        // 计算平均分
        let avgScore = calculateAverageScore(from: sessions)
        
        // 生成报告
        let report = AnalysisResult(
            score: avgScore,
            summary: generateSummary(score: avgScore, profile: profile),
            strengths: generateStrengths(profile: profile),
            improvements: generateImprovements(score: avgScore),
            suggestions: generateSuggestions(profile: profile, score: avgScore),
            emotionalTrend: analyzeEmotionalTrend(sessions: sessions),
            communicationQuality: assessCommunicationQuality(sessions: sessions),
            nextReviewDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        )
        
        return report
    }
    
    /// 获取智能建议
    func getSuggestions(for profile: Profile) async -> [String] {
        // 基于关系类型和时间生成个性化建议
        var suggestions: [String] = []
        
        let calendar = Calendar.current
        let now = Date()
        
        // 关系类型相关建议
        switch profile.relationship {
        case .partner, .spouse:
            suggestions.append(contentsOf: [
                "今天可以给对方一个惊喜，表达你的感激之情",
                "一起回忆初次相遇的美好时光",
                "尝试一起完成一个新活动，增加共同回忆"
            ])
        case .family:
            suggestions.append(contentsOf: [
                "给家人打个电话，关心近况",
                "分享一些生活中的趣事",
                "一起用餐，增进感情"
            ])
        case .friend:
            suggestions.append(contentsOf: [
                "约出来喝杯咖啡聊聊近况",
                "分享最近看到的有趣内容",
                "在重要日子送上祝福"
            ])
        case .colleague:
            suggestions.append(contentsOf: [
                "在工作中多给予支持和配合",
                "适当表达感谢和认可"
            ])
        case .other:
            suggestions.append("保持真诚和尊重的沟通")
        }
        
        // 生日相关建议
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
    
    // MARK: - Private Methods
    
    private func performAnalysis(recording: RecordingSession, profile: Profile) async throws -> AnalysisResult {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // 生成模拟结果
        let score = Int.random(in: 70...95)
        
        return AnalysisResult(
            score: score,
            summary: generateSummary(score: score, profile: profile),
            strengths: generateStrengths(profile: profile),
            improvements: generateImprovements(score: score),
            suggestions: generateSuggestions(profile: profile, score: score),
            emotionalTrend: "上升",
            communicationQuality: score > 80 ? "优秀" : "良好",
            nextReviewDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        )
    }
    
    private func calculateAverageScore(from sessions: [RecordingSession]) -> Int {
        guard !sessions.isEmpty else { return 75 }
        
        let total = sessions.reduce(0) { $0 + $1.analysisScore }
        return min(100, max(0, total / sessions.count))
    }
    
    private func generateSummary(score: Int, profile: Profile) -> String {
        let relationshipWord: String
        switch profile.relationship {
        case .partner, .spouse: relationshipWord = "伴侣关系"
        case .family: relationshipWord = "家庭关系"
        case .friend: relationshipWord = "友谊"
        case .colleague: relationshipWord = "同事关系"
        case .other: relationshipWord = "关系"
        }
        
        if score >= 85 {
            return "与\(profile.name)的\(relationshipWord)非常健康，双方都付出了真心和努力，保持这种良好的势头，继续用心经营。"
        } else if score >= 70 {
            return "与\(profile.name)的\(relationshipWord)总体良好，偶尔会有小摩擦，但都能妥善解决。继续保持沟通和理解。"
        } else if score >= 60 {
            return "与\(profile.name)的\(relationshipWord)需要更多关注和投入。建议增加有效沟通，相互理解彼此的需求。"
        } else {
            return "与\(profile.name)的\(relationshipWord)面临一些挑战。建议主动沟通，寻找共同点，逐步改善关系质量。"
        }
    }
    
    private func generateStrengths(profile: Profile) -> [String] {
        var strengths: [String] = []
        
        switch profile.relationship {
        case .partner, .spouse:
            strengths = [
                "双方有共同的价值观和目标",
                "愿意为对方付出和妥协",
                "沟通方式成熟理性",
                "相互支持彼此的个人发展"
            ]
        case .family:
            strengths = [
                "血缘纽带带来的天然信任",
                "愿意倾听和理解",
                "在困难时相互扶持"
            ]
        case .friend:
            strengths = [
                "相互尊重和支持",
                "有共同的兴趣爱好",
                "真诚相待"
            ]
        case .colleague:
            strengths = [
                "专业配合默契",
                "相互尊重边界",
                "有效的工作沟通"
            ]
        case .other:
            strengths = ["保持真诚和尊重"]
        }
        
        return strengths
    }
    
    private func generateImprovements(score: Int) -> [String] {
        if score >= 85 {
            return ["可以尝试更多深度交流", "适当保持个人空间"]
        } else if score >= 70 {
            return [
                "增加日常关心和互动",
                "更好地处理分歧和矛盾",
                "多表达感激之情"
            ]
        } else {
            return [
                "建立更稳定的沟通习惯",
                "学会倾听而非说教",
                "减少不必要的争执",
                "增加相处时间"
            ]
        }
    }
    
    private func generateSuggestions(profile: Profile, score: Int) -> [String] {
        var suggestions: [String] = []
        
        if score < 70 {
            suggestions.append("安排一次深入交流，坦诚分享彼此的感受和期望")
            suggestions.append("尝试每天说一句关心的话")
        }
        
        if profile.relationship == .partner || profile.relationship == .spouse {
            suggestions.append("可以一起看一部电影或共进晚餐")
        }
        
        suggestions.append("在重要日子给予特别关注")
        
        return suggestions
    }
    
    private func analyzeEmotionalTrend(sessions: [RecordingSession]) -> String {
        guard sessions.count >= 2 else { return "数据不足" }
        
        let sorted = sessions.sorted { $0.createdAt < $1.createdAt }
        let recent = sorted.suffix(3)
        let scores = recent.map { $0.analysisScore }
        
        guard scores.count >= 2 else { return "稳定" }
        
        let diff = scores.last! - scores.first!
        
        if diff > 10 {
            return "上升 📈"
        } else if diff < -10 {
            return "下降 📉"
        } else {
            return "稳定 ➡️"
        }
    }
    
    private func assessCommunicationQuality(sessions: [RecordingSession]) -> String {
        guard !sessions.isEmpty else { return "暂无数据" }
        
        let avgScore = calculateAverageScore(from: sessions)
        
        switch avgScore {
        case 90...100: return "卓越"
        case 80..<90: return "优秀"
        case 70..<80: return "良好"
        case 60..<70: return "一般"
        default: return "需要改善"
        }
    }
    
    // MARK: - Quota Management
    
    private func checkAndResetDailyQuota() {
        let today = Calendar.current.startOfDay(for: Date())
        if let lastDate = userDefaults.object(forKey: dateKey) as? Date {
            let lastDay = Calendar.current.startOfDay(for: lastDate)
            if lastDay < today {
                // 新的一天，重置配额
                usedToday = 0
            } else {
                // 同一天，恢复使用量
                usedToday = userDefaults.integer(forKey: usedKey)
            }
        }
        dailyQuota = 3
    }
    
    private func saveUsage() {
        userDefaults.set(usedToday, forKey: usedKey)
        userDefaults.set(Date(), forKey: dateKey)
    }
}

// MARK: - RelationshipType Extension for Display

extension RelationshipType {
    var displayName: String {
        switch self {
        case .partner: return "伴侣"
        case .spouse: return "配偶"
        case .family: return "家人"
        case .friend: return "朋友"
        case .colleague: return "同事"
        case .other: return "其他"
        }
    }
}