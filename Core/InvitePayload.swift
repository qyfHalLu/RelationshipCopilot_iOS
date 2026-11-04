//
// InvitePayload.swift
// 关系Copilot
//
// 对方网页提交的**明文正文**在解密后长什么样，以及它怎么变成 `DisputeTestimony`。
//
// ## 为什么值得单独一个文件
//
// 这是全流程里唯一一处"外部输入"：内容由别人的浏览器产生，
// 我们既没有 schema 校验，也没法在服务端拒绝畸形数据（服务端读不懂它）。
// 所以解析必须自己做，而且必须对**每一种畸形**都有明确行为，
// 而不是靠 `try?` 吞掉。
//
// 特别要注意的是：解出来的东西**不一定来自我们那个网页**。
// 密钥在链接里，任何拿到链接的人都能用自己的程序写一份合法的密文上来。
// 所以这里不能假设字段齐全、不能假设长度合规 —— 一切都要检查。
//
// ## 与 Swift 侧题目表的对应
//
// 网页的四题 id 与 `TestimonyQuestion` 的 case 名**必须逐字相同**
// （`happened` / `hurtMost` / `request` / `myPart`）。
// 这个对应关系由 `Tools/ai-proxy/invite.test.mjs` 里的「题目数：网页 vs App」
// 段落守着 —— 那边直接读 Swift 源码解析 case 名，所以改名会立刻报红。
//

import Foundation
import CryptoKit

/// 对方网页提交的原始结构（解密后的 JSON）。
struct InvitePayload: Decodable, Equatable {

    /// 提交方自称的位置。仅用于 sanity check，不用于决定写入哪一侧 ——
    /// 写哪一侧由服务端 KV 的键决定，那是**存储事实**而非自称。
    let slot: String?

    /// 四题回答。键是题目 id。
    let answers: [String: String]

    /// 提交时间（毫秒时间戳）。缺失或畸形时用当前时间兜底。
    let submittedAt: Double?

    enum CodingKeys: String, CodingKey {
        case slot, answers, submittedAt
    }

    // MARK: 转成证词

    /// 转成 App 内部的证词结构。
    ///
    /// - Returns: 四题齐备时返回证词；缺题时返回 nil。
    ///
    /// 为什么缺题就整份拒绝，而不是"缺的填占位、其余照收"：
    /// 一份缺了「这件事里你自己那一份」的证词，会让模型倾向于把责任
    /// 全部归到写了四题的那一侧 —— 而这一侧恰恰是发起方自己。
    /// 那种结果看起来是"评理"，实际上是把一次漏填当成了自我批评的反面证据。
    /// 宁可让界面说"TA 那份没写全，请让对方重写"，也不要产出一个有偏的结论。
    func toTestimony() -> DisputeTestimony? {
        var testimony = DisputeTestimony()
        for question in TestimonyQuestion.allCases {
            // 题目 id 用 case 名的字符串。`TestimonyQuestion` 目前没有
            // 显式的 id 属性，所以这里用反射式的映射而不是硬编码 switch ——
            // 硬编码 switch 在加第五题时会静默漏掉（默认返回空串 = 视为未填），
            // 而那种漏掉表现为"对方明明写了，这边说没写"。
            guard let raw = answers[Self.webID(for: question)] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            testimony.setAnswer(trimmed, for: question)
        }

        if let submittedAt {
            // 网页给的是毫秒。秒级时间戳（10 位）按毫秒解释会变成 1970 年，
            // 所以按数量级判断，而不是一律除以 1000。
            let seconds = submittedAt > 1_000_000_000_000 ? submittedAt / 1000 : submittedAt
            testimony.submittedAt = Date(timeIntervalSince1970: seconds)
        }
        return testimony
    }

    /// 题目 → 网页里的字段名。
    ///
    /// 刻意用显式 switch 而不是 `String(describing:)`：
    /// 反射拿到的是 case 名，改成显式之后，如果哪天有人重命名了 case，
    /// 这里会编译报错，而不是在运行时默默对不上。
    static func webID(for question: TestimonyQuestion) -> String {
        switch question {
        case .happened: return "happened"
        case .hurtMost: return "hurtMost"
        case .request:  return "request"
        case .myPart:   return "myPart"
        }
    }

    /// 缺了哪几题（供界面如实说明，而不是只说一句"格式不对"）。
    func missingQuestions() -> [TestimonyQuestion] {
        TestimonyQuestion.allCases.filter { question in
            let raw = answers[Self.webID(for: question)] ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

// MARK: - 解密 + 解析

enum InvitePayloadError: LocalizedError, Equatable {
    /// 密文解不开：密钥不对，或内容被动过。
    case cannotOpen
    /// 解开了，但不是我们认识的 JSON。
    case malformed(String)
    /// 缺题。
    case incomplete([String])

    var errorDescription: String? {
        switch self {
        case .cannotOpen:
            return "TA 写的那一份解不开。链接可能被改过，或者内容已损坏。"
        case .malformed(let detail):
            return "TA 那一份的格式不对（\(detail)）。"
        case .incomplete(let missing):
            return "TA 那一份还缺 \(missing.count) 题没写。"
        }
    }
}

extension InviteCrypto {

    /// 解密对方提交的密文并解析成证词。
    ///
    /// 把"解密"和"解析"放在一起，是因为调用方**永远不需要**中间那层字符串。
    /// 分开暴露只会诱使某处打印出明文来调试 —— 而这正是本项目要避免的事。
    static func openPayload(_ sealed: InviteCiphertext, key: SymmetricKey) throws -> InvitePayload {
        let plaintext: String
        do {
            plaintext = try open(sealed, key: key)
        } catch {
            throw InvitePayloadError.cannotOpen
        }

        guard let data = plaintext.data(using: .utf8) else {
            throw InvitePayloadError.malformed("不是 UTF-8 文本")
        }

        let payload: InvitePayload
        do {
            payload = try JSONDecoder().decode(InvitePayload.self, from: data)
        } catch {
            throw InvitePayloadError.malformed("不是预期的 JSON")
        }
        return payload
    }
}
