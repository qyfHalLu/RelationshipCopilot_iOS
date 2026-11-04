//
//  RelationshipType.swift
//  RelationshipCopilot
//
//  关系类型：唯一事实来源
//  修复报告 A3：关系类型 → 中文映射原先在 AIService / ProfilesView / AddProfileView 各写一份，
//  且 ProfilesView 的副本漏了 spouse（配偶显示为「其他」）。
//

import Foundation

/// 关系类型。以 `String` 持久化，保证 SwiftData 存量数据（`Profile.relationshipType`）可直接解码。
enum RelationshipType: String, CaseIterable, Identifiable, Sendable {
    case partner
    case spouse
    case family
    case friend
    case colleague
    /// 同居室友。泛人际定位下这是高频场景：生活摩擦多、但不是亲密关系，
    /// 评理时的语气与"伴侣"完全不同，所以单列而不是塞进 `.other`。
    case roommate
    case other

    var id: String { rawValue }

    /// 面向用户的中文名称。所有页面必须从这里取，不得各自 switch。
    var displayName: String {
        switch self {
        case .partner:   return "伴侣"
        case .spouse:    return "配偶"
        case .family:    return "家人"
        case .friend:    return "朋友"
        case .colleague: return "同事"
        case .roommate:  return "室友"
        case .other:     return "其他"
        }
    }

    /// 是否属于「亲密关系」。
    ///
    /// 用途在本轮改版中变了：原来只用来决定"要不要显示纪念日"，
    /// 现在**同时驱动评理的语气**（提示词里的 relationshipLabel）。
    /// 伴侣/配偶走亲密语气，其余走克制语气——这是唯一需要分叉的地方，
    /// 不需要为每种关系各写一套提示词。
    var isIntimate: Bool {
        self == .partner || self == .spouse
    }

    /// 评理提示词里使用的关系标签。
    /// 刻意只区分「亲密关系」与「其他关系」，避免提示词数量爆炸。
    var disputeLabel: String {
        isIntimate ? displayName : "\(displayName)（非亲密关系）"
    }

    /// 宽容解析：未知字符串不丢弃、不崩溃，统一落到 `.other`。
    /// 存量数据里若存在历史拼写（如 "lover"），也会安全降级。
    static func parse(_ raw: String?) -> RelationshipType {
        guard let raw, let value = RelationshipType(rawValue: raw) else { return .other }
        return value
    }
}
