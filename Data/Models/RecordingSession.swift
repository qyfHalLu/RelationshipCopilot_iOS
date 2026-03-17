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
}

// MARK: - 分析结果结构
struct AnalysisResult: Codable {
    var emotionScore: Double?
    var communicationPatterns: [String]?
    var recommendations: [String]?
    var summary: String?
    var keywords: [String]?
}
