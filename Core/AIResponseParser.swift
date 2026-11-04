//
//  AIResponseParser.swift
//  RelationshipCopilot
//
//  AI 返回内容的解析器。
//  修复报告 A2 / A6 / D2：
//   - 原实现 `AIService.parseAnalysisResult` 在缺字段时用 `?? 75` 补齐，会**静默编造关系评分**；
//   - 原实现解析出 emotionalTrend / communicationQuality 后直接丢弃；
//   - 原实现字段语义错位（communicationPatterns 存 strengths、keywords 存 improvements）。
//
//  本解析器改为：缺字段就返回 nil，绝不编造；并把 7 个字段全部保留。
//  纯函数、无框架依赖，可直接单测。
//

import Foundation

/// AI 分析结果（解析层产物，与持久化 DTO 解耦）。
struct ParsedAnalysis: Sendable, Equatable {
    /// 0...100。**缺失时是 nil，不是 75** —— 调用方必须显式处理"无法评分"。
    var score: Int?
    var summary: String?
    var strengths: [String]
    var improvements: [String]
    var suggestions: [String]
    var emotionalTrend: String?
    var communicationQuality: String?

    var hasUsableContent: Bool {
        score != nil
            || !(summary ?? "").isEmpty
            || !strengths.isEmpty
            || !improvements.isEmpty
            || !suggestions.isEmpty
    }

    init(
        score: Int? = nil,
        summary: String? = nil,
        strengths: [String] = [],
        improvements: [String] = [],
        suggestions: [String] = [],
        emotionalTrend: String? = nil,
        communicationQuality: String? = nil
    ) {
        self.score = score
        self.summary = summary
        self.strengths = strengths
        self.improvements = improvements
        self.suggestions = suggestions
        self.emotionalTrend = emotionalTrend
        self.communicationQuality = communicationQuality
    }
}

enum AIResponseParserError: LocalizedError, Equatable {
    case empty
    case notJSON
    case noUsableContent

    var errorDescription: String? {
        switch self {
        case .empty:          return "AI 返回内容为空"
        case .notJSON:        return "AI 返回的不是有效 JSON"
        case .noUsableContent: return "AI 返回内容缺少可用字段"
        }
    }
}

enum AIResponseParser {

    /// 从模型输出中提取 JSON 并解析。
    /// 容忍：```json 围栏、前后解释性文字、数字被包成字符串、score 越界。
    static func parse(_ raw: String) throws -> ParsedAnalysis {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIResponseParserError.empty }

        guard let jsonText = extractJSONObject(from: trimmed) else {
            throw AIResponseParserError.notJSON
        }
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw AIResponseParserError.notJSON
        }

        let result = ParsedAnalysis(
            score: intValue(dict["score"]).flatMap { (0...100).contains($0) ? $0 : nil },
            summary: nonEmptyString(dict["summary"]),
            strengths: stringArray(dict["strengths"]),
            improvements: stringArray(dict["improvements"]),
            suggestions: stringArray(dict["suggestions"]),
            emotionalTrend: nonEmptyString(dict["emotionalTrend"]),
            communicationQuality: nonEmptyString(dict["communicationQuality"])
        )

        guard result.hasUsableContent else { throw AIResponseParserError.noUsableContent }
        return result
    }

    /// 裁剪出最外层平衡的 `{...}`，跳过 ```json 围栏与前后说明文字。
    static func extractJSONObject(from text: String) -> String? {
        var working = text

        // 去掉 markdown 围栏（可能出现 ```json / ```JSON / ```）
        if let fenceStart = working.range(of: "```") {
            working = String(working[fenceStart.upperBound...])
            if let newline = working.firstIndex(where: { $0 == "\n" }) {
                let firstLine = working[working.startIndex..<newline]
                // 围栏语言标记行（json / JSON / swift 等）整行丢弃
                if firstLine.trimmingCharacters(in: .whitespaces).count <= 12,
                   !firstLine.contains("{") {
                    working = String(working[working.index(after: newline)...])
                }
            }
            if let fenceEnd = working.range(of: "```", options: .backwards) {
                working = String(working[..<fenceEnd.lowerBound])
            }
        }

        guard let start = working.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < working.endIndex {
            let char = working[index]
            if escaped {
                escaped = false
            } else if char == "\\" && inString {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(working[start...index])
                    }
                }
            }
            index = working.index(after: index)
        }
        return nil
    }

    // MARK: - 宽容取值

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let value as Int: return value
        case let value as Double:
            guard value.isFinite else { return nil }
            return Int(value.rounded())
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespaces))
        case let value as NSNumber: return value.intValue
        default: return nil
        }
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let value = any as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringArray(_ any: Any?) -> [String] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { element in
            if let string = element as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
    }
}
