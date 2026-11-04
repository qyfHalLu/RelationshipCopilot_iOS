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
    /// 纪念日。修复报告 C：原先用户在 AddProfileView 填写的纪念日被静默丢弃
    /// （`AddProfileView.swift:236-238` 是一个空 if 分支，只留了注释）。
    var anniversary: Date?
    /// 通用备注。修复报告 A6：原 `notes` 把内容写进 `preferences.communicationStyle`
    /// （「备注」存进「沟通风格」）。新增独立字段承载，可选类型可由 SwiftData 轻量迁移自动添加。
    var note: String?
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

    /// 强类型的关系类型。
    /// 修复报告 A3：中文映射原先在 AIService / ProfilesView / AddProfileView 各写一份，
    /// 且 ProfilesView 的副本漏了 spouse（配偶被显示成「其他」）。
    var relationship: RelationshipType {
        get { RelationshipType.parse(relationshipType) }
        set { relationshipType = newValue.rawValue }
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

// MARK: - 亲密度与备注（唯一计算入口）
//
// 说明：不在 `@Model` 属性上加 `didSet`。SwiftData 宏会把存储属性重写为
// 由 backing data 支撑的计算属性，属性观察器在该场景下行为不可靠。
// 因此所有写入都走下面的显式方法，由方法负责夹取范围。
//
// 改版说明：`healthScore` / `healthBand` 已**整体删除**。
// 原因见 Core/IntimacyScale.swift 头部：那个分数是 `70 + intimacy * 3`，
// 即把用户自己拖的滑块线性映射成一个看似测量值的两位数。
// 现在 `intimacyScore` 只作为用户主动标注的「关系距离」使用。
extension Profile {

    /// 亲密度的展示标签（"很近" / "一般" / "有距离"…）。**不是评分。**
    var intimacyLabel: String {
        IntimacyScale.label(for: intimacyScore)
    }

    /// 设置亲密度并夹取到 0...10。所有 UI 写入点都应调用它。
    func setIntimacy(_ value: Int) {
        intimacyScore = IntimacyScale.clamp(value)
        updatedAt = Date()
    }

    /// 备注。写入落到独立字段 `note`；读取时兼容历史数据
    /// （旧版本把备注存在 `preferences.communicationStyle` 里）。
    var notes: String? {
        get {
            if let note, !note.isEmpty { return note }
            let legacy = preferences?.communicationStyle
            return (legacy?.isEmpty == false) ? legacy : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            note = (trimmed?.isEmpty == true) ? nil : trimmed
            // 顺手把历史值迁出，避免继续占用「沟通风格」字段
            if var prefs = preferences, prefs.communicationStyle != nil {
                prefs.communicationStyle = nil
                preferences = prefs
            }
        }
    }

    /// 存量数据修复：把被旧版 setter 写坏的 `intimacyScore` 夹回 0...10。
    /// 启动时对全部档案执行一次（修复报告 R6）。
    /// - Returns: 是否发生了修复。
    @discardableResult
    func repairIntimacyIfNeeded() -> Bool {
        let clamped = IntimacyScale.clamp(intimacyScore)
        guard clamped != intimacyScore else { return false }
        intimacyScore = clamped
        return true
    }
}
