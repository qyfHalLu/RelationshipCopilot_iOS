//
//  DisputeCaseState.swift
//  RelationshipCopilot
//
//  案卷的流程状态机。**纯逻辑，不碰 SwiftData**，可直接单测。
//
//  为什么要把状态机单独抽出来：
//  同机双人流程最危险的不是 AI 说错话，是**流程漏气** ——
//  比如 A 提交后界面没锁死，B 顺手看到了 A 写的内容；
//  或者 B 还没写，生成按钮就能点，模型拿着半份证词开始评理。
//  这类 bug 在 SwiftUI 里很难靠点几下发现，必须用状态机断言钉住。
//
//  流程（sameDevice）：
//    collectingA ──A 提交──▶ waitingForB ──递设备──▶ collectingB ──B 提交──▶ ready ──生成──▶ closed
//         ▲                                                                                    │
//         └──────────────────────── 重新开一次（保留原证词）──────────────────────────────────┘
//
//  流程（solo）：
//    collectingA ──提交──▶ ready ──生成──▶ closed
//
//  blocked 是安全拦截态的终点：命中高危词后**不允许**继续到 ready/closed。
//

import Foundation

// MARK: - 参与方

/// 案卷的两位当事人。持久化为 `a` / `b`，界面上一律显示「你」/「TA」。
enum DisputeParty: String, Codable, Sendable, CaseIterable {
    case a
    case b

    /// 界面上的第一人称/第三人称称呼。
    ///
    /// 刻意不用「甲方/乙方」——那是合同语言，会把亲密关系推向对抗框架。
    var displayName: String {
        switch self {
        case .a: return "你"
        case .b: return "TA"
        }
    }
}

// MARK: - 状态

/// 案卷状态。以 `String` 持久化（SwiftData 存字符串，强类型由此派生）。
enum DisputeCaseState: String, Codable, Sendable, CaseIterable {

    /// A 正在写（同机模式的起点；solo 模式的唯一书写态）。
    case collectingA

    /// A 已提交并锁死，设备该递给对方了。
    ///
    /// 这个状态存在的唯一目的，是给界面一个**必须停一下**的位置：
    /// 屏幕上不显示任何内容，只有一句「把手机给对方」。
    case waitingForB

    /// B 正在写。此时 A 的证词在内存里，但**不得渲染**。
    case collectingB

    /// 双方都已提交，可以生成第三方之见。
    case ready

    /// 已出结果。
    case closed

    /// 安全拦截。不允许继续评理。
    case blocked

    // MARK: 展示

    var displayName: String {
        switch self {
        case .collectingA: return "你在写"
        case .waitingForB: return "等对方写"
        case .collectingB: return "TA 在写"
        case .ready:       return "可以看了"
        case .closed:      return "已出结果"
        case .blocked:     return "已停止"
        }
    }

    /// 是否处于「正在收集证词」阶段。此阶段的数据只在内存/草稿里，不生成。
    var isCollecting: Bool {
        self == .collectingA || self == .waitingForB || self == .collectingB
    }

    /// 是否允许调用模型。
    ///
    /// **只有 ready 允许。** 这是「不许拿半份证词评理」的代码级保证，
    /// 不依赖任何按钮的 `disabled` 表达式。
    var allowsJudging: Bool { self == .ready }

    /// 是否处于终态（不再接受输入）。
    var isTerminal: Bool { self == .closed || self == .blocked }
}

// MARK: - 状态迁移

extension DisputeCaseState {

    /// 当前状态是否可以迁移到目标状态。
    ///
    /// 显式白名单而非黑名单：新增状态时必须在这里想清楚它的进出路径，
    /// 否则「不小心漏了一个状态」就会变成「悄悄允许了一条不该存在的路径」。
    func canTransition(to next: DisputeCaseState, mode: DisputeMode) -> Bool {
        guard next != self else { return true }

        // 双人语义的转移规则对 `sameDevice` 与 `remote` 完全相同：
        // 都是"A 写完 → 停一下 → B 写 → 出结果"。
        //
        // 差别只在"停一下"那一步做什么 —— 同机是把手机递过去，
        // 远程是等对方在自己设备上写完。**状态机不需要知道这个区别**，
        // 否则每加一种收集方式就要改一遍状态表。
        //
        // 早先这里写的是 `mode == .sameDevice`，加 remote 后
        // 远程模式提交会卡在 `collectingA` 出不去 —— 而编译器不会报错，
        // 因为 `.solo` 那条分支还兜着，看起来"合法"。
        let isTwoParty = mode.isTwoParty

        switch (self, next) {

        // 起点
        case (.collectingA, .waitingForB):
            return isTwoParty
        case (.collectingA, .ready):
            return mode == .solo
        case (.collectingA, .blocked):
            return true

        // 递交
        case (.waitingForB, .collectingB):
            return isTwoParty
        // 递错设备想退回去重写
        case (.waitingForB, .collectingA):
            return isTwoParty

        // B 写完
        case (.collectingB, .ready):
            return isTwoParty
        // B 想重写
        case (.collectingB, .collectingB):
            return true
        case (.collectingB, .collectingA):
            // 只有同机能退回上一位重写 —— 远程模式下 A 的设备上根本没有
            // "正在写的 B"，退回 A 重新写会把已经传回来的那份证词丢掉。
            return mode.isHandoverByDevice
        case (.collectingB, .blocked):
            return true

        // 生成
        case (.ready, .closed):
            return true
        case (.ready, .blocked):
            return true
        // 生成失败退回可重试
        case (.ready, .ready):
            return true

        // 重新打开（保留证词，只重新生成）
        case (.closed, .ready):
            return true
        case (.closed, .collectingA):
            return true

        // 安全拦截后，用户改完内容可以重来
        case (.blocked, .collectingA):
            return true

        default:
            return false
        }
    }

    /// 迁移并断言。失败即返回原状态 —— 调用方不得依赖"顺手成功"。
    func transition(to next: DisputeCaseState, mode: DisputeMode) -> DisputeCaseState {
        canTransition(to: next, mode: mode) ? next : self
    }
}

// MARK: - 完整性闸门

/// 生成前的最后一道检查。**在 UI 与 Service 两侧都要调**，
/// 确保"能点生成"和"能真的调模型"是同一个判断，不会各写一份而漂移。
enum DisputeCaseGate {

    enum Rejection: Equatable {
        case stateNotReady(DisputeCaseState)
        /// 同机模式下缺一份证词。
        case missingTestimony(DisputeParty)
        /// 某份证词四题没填满。
        case incompleteTestimony(DisputeParty)
        /// 安全拦截。
        case safetyBlocked([SafetyConcern])

        var message: String {
            switch self {
            case .stateNotReady(let state):
                return "现在还不到生成的时候（当前：\(state.displayName)）。"
            case .missingTestimony(let party):
                return "\(party.displayName)那一份还没写。"
            case .incompleteTestimony(let party):
                return "\(party.displayName)那一份还有问题没回答完。"
            case .safetyBlocked:
                return "内容涉及安全风险，已停止评理。"
            }
        }
    }

    /// 检查是否可生成。
    /// - Returns: nil 表示通过。
    static func check(
        state: DisputeCaseState,
        mode: DisputeMode,
        sideA: DisputeTestimony?,
        sideB: DisputeTestimony?
    ) -> Rejection? {
        guard state.allowsJudging else {
            return .stateNotReady(state)
        }

        guard let sideA, sideA.isComplete else {
            return sideA == nil ? .missingTestimony(.a) : .incompleteTestimony(.a)
        }

        // 双人语义（同机 + 远程）都必须有完整的 B。
        //
        // 早先这里写的是 `mode == .sameDevice`，加 remote 之后
        // 远程模式会**跳过 B 的全部检查**：B 没写也能生成、B 只写两题也能生成。
        // 而 `DisputeCaseState.ready` 在那里是可到达的（状态机本身没错），
        // 于是整条闸门形同不存在，且编译器不会提示 ——
        // 因为 `.solo` 的语义里 B 本来就该是 nil，两个分支看起来都"合理"。
        if mode.isTwoParty {
            guard let sideB, sideB.isComplete else {
                return sideB == nil ? .missingTestimony(.b) : .incompleteTestimony(.b)
            }
        }

        // 安全筛查：任一侧命中即拦
        let screeningA = SafetyScreen.screen(sideA)
        if screeningA.isBlocking {
            return .safetyBlocked(screeningA.concerns)
        }
        if mode.isTwoParty, let sideB {
            let screeningB = SafetyScreen.screen(sideB)
            if screeningB.isBlocking {
                return .safetyBlocked(screeningB.concerns)
            }
        }
        return nil
    }
}
