import SwiftData
import Foundation

// MARK: - 用户模型
@Model
final class User {
    @Attribute(.unique) var id: UUID
    var phone: String
    var nickname: String?
    var avatar: String?
    var status: String          // active, suspended, deleted
    var subscription: String    // free, monthly, quarterly, yearly
    var createdAt: Date
    var updatedAt: Date
    
    @Relationship(deleteRule: .cascade)
    var profiles: [Profile]?
    
    init(id: UUID = UUID(), phone: String) {
        self.id = id
        self.phone = phone
        self.status = "active"
        self.subscription = "free"
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
