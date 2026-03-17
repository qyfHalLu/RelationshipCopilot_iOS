import SwiftData
import Foundation

// MARK: - 承诺模型
@Model
final class Promise {
    @Attribute(.unique) var id: UUID
    var content: String
    var contentSummary: String?
    var commitmentType: String?  // behavior_change, emotion_control, habit_formation
    var promisor: String         // user, partner
    var promisee: String         // user, partner
    var level: String            // core, normal, recorded
    var trackingStatus: String   // active, paused, closed
    var committedAt: Date
    var deadline: Date?
    var recurrence: String?      // once, daily, weekly, monthly
    var fulfillmentRate: Double
    var streakDays: Int
    var lastCheckIn: Date?
    var confidenceScore: Double?
    var strength: String?        // strong, medium, weak
    var createdAt: Date
    var updatedAt: Date
    
    @Relationship
    var profile: Profile?
    
    @Relationship(deleteRule: .cascade)
    var fulfillmentRecords: [FulfillmentRecord]?
    
    init(content: String, promisor: String, promisee: String) {
        self.id = UUID()
        self.content = content
        self.promisor = promisor
        self.promisee = promisee
        self.level = "normal"
        self.trackingStatus = "active"
        self.committedAt = Date()
        self.fulfillmentRate = 0
        self.streakDays = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - 履约记录模型
@Model
final class FulfillmentRecord {
    @Attribute(.unique) var id: UUID
    var recordDate: Date
    var status: String           // fulfilled, partial, pending, missed
    var detectionSource: String? // system_detection, user_self_report, partner_confirm
    var detectionScore: Double?
    var evidence: String?
    var userRating: Int?
    var userNote: String?
    var createdAt: Date
    
    @Relationship
    var promise: Promise?
    
    init(recordDate: Date, status: String) {
        self.id = UUID()
        self.recordDate = recordDate
        self.status = status
        self.createdAt = Date()
    }
}
