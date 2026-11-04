//
//  DisputeEvaluation.swift
//  RelationshipCopilot
//
//  评理能力的对外契约（纯逻辑，无框架依赖）。
//
//  为什么不直接返回 `DisputeVerdict`：
//  评理有三种结局，"失败"不是一种 ——
//    ① 正常出结果
//    ② 命中安全风险，**主动不给结果**（这是正确行为，不是错误）
//    ③ 模型没给出可用结果，降级为原话摘录
//  把它们压成一个 `throws` 会让 UI 把 ② 当异常处理，从而写出
//  "评理失败，请重试" 这种在自伤/暴力语境下极其不当的文案。
//

import Foundation

// MARK: - 结局

enum DisputeOutcome: Equatable, Sendable {
    /// 正常产出第三方之见。
    case verdict(DisputeVerdict)

    /// 命中安全风险。**不是错误**，是拒绝评理。
    case blocked(SafetyGuidance)

    /// 模型没给出可用结果，降级为双方原话对称摘录。
    /// 关联值里保留失败原因，供"重试"按钮与诊断使用。
    case fallback(DisputeVerdict, reason: String)

    /// 便于 UI 统一取展示用的评理结果（blocked 时为 nil）。
    var verdict: DisputeVerdict? {
        switch self {
        case .verdict(let value):  return value
        case .fallback(let value, _): return value
        case .blocked:             return nil
        }
    }

    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    /// 是否属于"没能真正评理"（UI 据此决定是否显示重试）。
    var isDegraded: Bool {
        if case .fallback = self { return true }
        return false
    }
}

// MARK: - 请求

/// 一次评理请求的完整输入。UI 只负责组装它，不做任何业务判断。
struct DisputeRequest: Equatable, Sendable {
    let mode: DisputeMode
    let relationshipLabel: String
    let sideA: DisputeTestimony
    /// 同机模式必填；单机模式必须为 nil（否则就是"假装中立"）。
    let sideB: DisputeTestimony?

    init(mode: DisputeMode, relationshipLabel: String, sideA: DisputeTestimony, sideB: DisputeTestimony?) {
        self.mode = mode
        self.relationshipLabel = relationshipLabel
        self.sideA = sideA
        // 单机模式强制抹掉 B，从类型层面杜绝"单方数据走进双人提示词"。
        //
        // 判断必须用 `isTwoParty` 而不是 `mode == .sameDevice` ——
        // 后者在远程模式下会把对方辛苦写完、加密传回来的那一份**静默丢掉**，
        // 然后模型拿着半份证词去"评理"。这条错误特别隐蔽：
        // 请求照样成功、JSON 照样解析、界面照样出结果，
        // 只是那个结果从头到尾只读过一个人的话。
        self.sideB = mode.isTwoParty ? sideB : nil
    }

    /// 本地估算的 token 消耗（用于 TPM 预检）。
    var estimatedTokens: Int {
        let system = DisputePrompt.systemPrompt(mode: mode, relationshipLabel: relationshipLabel)
        return TokenEstimator.estimateDisputeRequest(
            systemPrompt: system,
            testimonyA: DisputePrompt.sameDeviceUserMessage(
                a: sideA,
                b: sideB ?? DisputeTestimony()
            ),
            testimonyB: "",
            maxOutputTokens: DisputePrompt.maxOutputTokens
        )
    }

    /// 提交前的完整性校验（与 UI 的按钮可用性共用同一个判断）。
    func gateRejection(state: DisputeCaseState) -> DisputeCaseGate.Rejection? {
        DisputeCaseGate.check(state: state, mode: mode, sideA: sideA, sideB: sideB)
    }
}

// MARK: - 能力协议

/// 评理能力。View 依赖协议而非单例，便于预览与测试注入。
protocol DisputeEvaluating: Sendable {
    /// 生成第三方之见。
    ///
    /// 只有"网络/服务/配额"这类真正的故障才 `throws`；
    /// 安全拦截与生成失败都以 `DisputeOutcome` 返回，由 UI 正常渲染。
    func evaluate(_ request: DisputeRequest) async throws -> DisputeOutcome
}
