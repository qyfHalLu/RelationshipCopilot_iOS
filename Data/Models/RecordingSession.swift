import SwiftData
import Foundation

// MARK: - 录音会话模型
@Model
final class RecordingSession {
    @Attribute(.unique) var id: UUID
    var sessionType: String      // conflict, conversation, other
    var status: String           // recording, completed, analyzed
    var startedAt: Date
    var endedAt: Date?
    var duration: TimeInterval?
    var audioFileURL: String?
    var transcription: String?
    var analysisResultData: Data?  // JSON存储分析结果
    var createdAt: Date

    @Relationship
    var profile: Profile?

    var analysisResult: AnalysisResult? {
        get {
            guard let data = analysisResultData else { return nil }
            return try? JSONDecoder().decode(AnalysisResult.self, from: data)
        }
        set {
            analysisResultData = try? JSONEncoder().encode(newValue)
        }
    }

    init(sessionType: String) {
        self.id = UUID()
        self.sessionType = sessionType
        self.status = "recording"
        self.startedAt = Date()
        self.createdAt = Date()
    }

    convenience init(
        sessionType: SessionKind,
        profile: Profile?,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        audioFileURL: URL? = nil
    ) {
        self.init(sessionType: sessionType.rawValue)
        self.profile = profile
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = endedAt.map { $0.timeIntervalSince(startedAt) }
        self.audioFileURL = audioFileURL?.path
        self.status = SessionStatus.completed.rawValue
    }
}

// MARK: - 枚举视图
enum SessionKind: String, Sendable {
    case conflict
    case conversation
    case other

    var displayName: String {
        switch self {
        case .conflict:     return "冲突复盘"
        case .conversation: return "日常对话"
        case .other:        return "其他记录"
        }
    }
}

enum SessionStatus: String, Sendable {
    case recording
    case completed
    case analyzed

    var displayName: String {
        switch self {
        case .recording: return "录音中"
        case .completed: return "待分析"
        case .analyzed:  return "已分析"
        }
    }
}

extension RecordingSession {
    var kind: SessionKind { SessionKind(rawValue: sessionType) ?? .other }
    var state: SessionStatus { SessionStatus(rawValue: status) ?? .completed }
}

// MARK: - 分析结果
//
// 修复报告 A6 / D2：
//  - 原 `AnalysisResult` 只有 5 个字段，`emotionalTrend` 与 `communicationQuality`
//    被解析出来后直接丢弃（AIService.swift:340-341 的警告即为此）；
//  - 原字段语义错位：`communicationPatterns` 存 strengths、`keywords` 存 improvements；
//  - 现在补 2 个字段（可选，可由 SwiftData/JSON 向后兼容解码），并提供语义访问器。
struct AnalysisResult: Codable, Equatable {
    /// 0...100。nil 表示模型未给出可信评分（绝不补默认值）。
    var emotionScore: Double?
    var communicationPatterns: [String]?   // 语义 = strengths
    var recommendations: [String]?         // 语义 = suggestions
    var summary: String?
    var keywords: [String]?                // 语义 = improvements
    var emotionalTrend: String?
    var communicationQuality: String?

    // MARK: 语义访问器（UI 应使用这些名字，避免继续传播错位命名）

    var scoreValue: Int? {
        guard let emotionScore, emotionScore.isFinite else { return nil }
        return min(100, max(0, Int(emotionScore.rounded())))
    }

    var strengths: [String] { communicationPatterns ?? [] }
    var improvements: [String] { keywords ?? [] }
    var suggestions: [String] { recommendations ?? [] }

    var hasContent: Bool {
        scoreValue != nil
            || !(summary ?? "").isEmpty
            || !strengths.isEmpty
            || !improvements.isEmpty
            || !suggestions.isEmpty
    }

    init(
        emotionScore: Double? = nil,
        communicationPatterns: [String]? = nil,
        recommendations: [String]? = nil,
        summary: String? = nil,
        keywords: [String]? = nil,
        emotionalTrend: String? = nil,
        communicationQuality: String? = nil
    ) {
        self.emotionScore = emotionScore
        self.communicationPatterns = communicationPatterns
        self.recommendations = recommendations
        self.summary = summary
        self.keywords = keywords
        self.emotionalTrend = emotionalTrend
        self.communicationQuality = communicationQuality
    }

    /// 由解析层产物构造。
    init(parsed: ParsedAnalysis) {
        self.init(
            emotionScore: parsed.score.map(Double.init),
            communicationPatterns: parsed.strengths.isEmpty ? nil : parsed.strengths,
            recommendations: parsed.suggestions.isEmpty ? nil : parsed.suggestions,
            summary: parsed.summary,
            keywords: parsed.improvements.isEmpty ? nil : parsed.improvements,
            emotionalTrend: parsed.emotionalTrend,
            communicationQuality: parsed.communicationQuality
        )
    }
}
