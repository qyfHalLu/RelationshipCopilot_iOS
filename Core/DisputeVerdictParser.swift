//
//  DisputeVerdictParser.swift
//  RelationshipCopilot
//
//  解析模型返回的「第三方之见」JSON，并做**客户端强制校验**。
//
//  与 `AIResponseParser` 的分工：
//   - `AIResponseParser` 解析旧的对话分析（strengths/improvements/suggestions），保留兼容
//   - 本文件解析评理结果，且**不做宽松兜底**：字段缺失即失败，绝不补默认值
//
//  为什么必须严格：
//  「补一个默认值」在情感类产品里等于编造。缺了 needB 就填「TA 也有自己的难处」，
//  用户会以为这是 AI 读出来的，实际是模板。这与硬编码 65 分是同一类错误。
//

import Foundation

enum DisputeVerdictParserError: LocalizedError, Equatable {
    case empty
    case notJSON
    case missingField(String)
    case invalidSolvability(String)
    case asymmetry(found: Double, required: Double)
    case forbiddenPhrases([String])
    case safetyBlocked

    var errorDescription: String? {
        switch self {
        case .empty:
            return "AI 返回内容为空"
        case .notJSON:
            return "AI 返回的不是有效 JSON"
        case .missingField(let name):
            return "AI 返回缺少字段：\(name)"
        case .invalidSolvability(let raw):
            return "AI 返回的可解性判定无法识别：\(raw)"
        case .asymmetry(let found, let required):
            return String(format: "双方呈现不对称（%.2f < %.2f）", found, required)
        case .forbiddenPhrases(let hits):
            return "AI 输出含禁用表述：\(hits.joined(separator: "、"))"
        case .safetyBlocked:
            return "内容涉及安全风险，已停止评理"
        }
    }
}

enum DisputeVerdictParser {

    /// 解析并校验。
    ///
    /// - Parameter raw: 模型返回的原始文本（可能是纯 JSON，也可能被 ``` 包裹，或夹在解释里）
    /// - Throws: 任一步失败都抛错，由调用方决定走「重试一次」还是「降级为原话摘录」
    static func parse(_ raw: String) throws -> DisputeVerdict {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DisputeVerdictParserError.empty }

        guard let jsonText = extractJSONObject(from: text) else {
            throw DisputeVerdictParserError.notJSON
        }
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DisputeVerdictParserError.notJSON
        }

        // 模型侧安全拒答：提示词约定输出 {"blocked": true, "reason": "..."}。
        // 必须在取 reframe 之前判断，否则会被当成"字段缺失"而走重试，
        // 白白多打一次请求（还会撞 TPM）。
        if let blocked = object["blocked"] as? Bool, blocked {
            throw DisputeVerdictParserError.safetyBlocked
        }

        // 必填字段：任一缺失即失败，不补默认值
        let reframe = try requiredString(object, "reframe")
        let needA = try requiredString(object, "needA")
        let needB = try requiredString(object, "needB")
        let stuckPoint = try requiredString(object, "stuckPoint")

        let rawKind = try requiredString(object, "solvability").lowercased()
        guard let solvability = DisputeSolvability(rawValue: rawKind) else {
            throw DisputeVerdictParserError.invalidSolvability(rawKind)
        }

        // 分流字段：可解决型必须有 action，永久型必须有 coexistence
        let action = optionalString(object, "action")
        let coexistence = optionalString(object, "coexistence")

        switch solvability {
        case .solvable:
            guard action != nil else {
                throw DisputeVerdictParserError.missingField("action")
            }
        case .perpetual:
            guard coexistence != nil else {
                throw DisputeVerdictParserError.missingField("coexistence")
            }
        }

        let verdict = DisputeVerdict(
            reframe: reframe,
            needA: needA,
            needB: needB,
            stuckPoint: stuckPoint,
            solvability: solvability,
            action: action,
            coexistence: coexistence
        )

        // 中立性校验：这是代码断言，不是提示词里的建议
        let symmetry = verdict.symmetry
        guard symmetry.passed else {
            throw DisputeVerdictParserError.asymmetry(
                found: symmetry.ratio,
                required: DisputeVerdict.symmetryThreshold
            )
        }

        // 内容守卫：禁用措辞
        let hits = verdict.forbiddenHits
        guard hits.isEmpty else {
            throw DisputeVerdictParserError.forbiddenPhrases(hits)
        }

        return verdict
    }

    // MARK: - 降级路径
    //
    // 两次解析都失败时（模型不稳定 / 拒答 / 格式漂移），**不编造评理结果**。
    // 改为把双方原话对称摘出来，明确标注"没能形成第三方之见"。
    // 这比给一个格式漂亮但内容杜撰的结果好得多。

    /// 从两份证词构造降级结果：只呈现双方各自的原话，不做任何推断。
    static func fallback(a: DisputeTestimony, b: DisputeTestimony, reason: String) -> DisputeVerdict {
        let needA = trimmedOrPlaceholder(a.answer(for: .hurtMost), fallback: "（这一侧没有写下来）")
        let needB = trimmedOrPlaceholder(b.answer(for: .hurtMost), fallback: "（这一侧没有写下来）")
        return DisputeVerdict(
            reframe: "这次没能给你们一个第三方之见。下面是你们各自写下的、最难受的那一点。",
            needA: needA,
            needB: needB,
            stuckPoint: "第三方之见生成失败（\(reason)）。你们可以据此自己谈，或稍后重试。",
            solvability: .perpetual,
            action: nil,
            coexistence: "在重新生成之前，可以先各自读一遍对方那一句——只是读，不回应。"
        )
    }

    private static func trimmedOrPlaceholder(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - 取值工具

    private static func requiredString(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] else {
            throw DisputeVerdictParserError.missingField(key)
        }
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DisputeVerdictParserError.missingField(key)
        }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalString(_ object: [String: Any], _ key: String) -> String? {
        guard let string = object[key] as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - JSON 提取
    //
    // 模型常见输出形态：纯 JSON / ```json 包裹 / "好的，结果如下：{...}"。
    // 只取第一个完整的顶层花括号块，避免把解释文字当 JSON。

    static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]

            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }

            index = text.index(after: index)
        }
        return nil
    }
}
