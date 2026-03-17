import SwiftData
import Foundation

// MARK: - 人物档案模型
@Model
final class Profile {
    var id: UUID
    var name: String
    var relationshipType: String
    var nickname: String?
    var avatar: String?
    var gender: String?
    var birthday: Date?
    var occupation: String?
    var relationshipStatus: String?
    var knownSince: Date?
    var intimacyScore: Int
    var interactionCount: Int
    var lastInteractionAt: Date?
    var createdAt: Date
    var updatedAt: Date
    
    // JSON存储字段
    var personalityData: Data?
    var preferencesData: Data?
    
    @Relationship(inverse: \User.profiles)
    var user: User?
    
    @Relationship(deleteRule: .cascade)
    var promises: [Promise]?
    
    @Relationship(deleteRule: .cascade)
    var recordingSessions: [RecordingSession]?
    
    // 计算属性
    var personality: Personality? {
        get {
            guard let data = personalityData else { return nil }
            return try? JSONDecoder().decode(Personality.self, from: data)
        }
        set {
            personalityData = try? JSONEncoder().encode(newValue)
        }
    }
    
    var preferences: Preferences? {
        get {
            guard let data = preferencesData else { return nil }
            return try? JSONDecoder().decode(Preferences.self, from: data)
        }
        set {
            preferencesData = try? JSONEncoder().encode(newValue)
        }
    }
    
    init(name: String, relationshipType: String) {
        self.id = UUID()
        self.name = name
        self.relationshipType = relationshipType
        self.intimacyScore = 5
        self.interactionCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - 辅助结构体
struct Personality: Codable {
    var traits: [String: String]?
    var mbti: String?
    var strengths: [String]?
    var weaknesses: [String]?
}

struct Preferences: Codable {
    var likes: [String]?
    var dislikes: [String]?
    var loveLanguage: String?
    var communicationStyle: String?
}
