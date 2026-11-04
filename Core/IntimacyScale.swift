//
//  IntimacyScale.swift
//  RelationshipCopilot
//
//  亲密度刻度的唯一事实来源。
//
//  —— 本文件是 `RelationshipHealth.swift` 的替代品 ——
//
//  **删除了什么、为什么删：**
//
//  原 `RelationshipHealth` 提供 `score = 70 + intimacy * 3`，把用户自己拖的
//  0...10 滑块线性映射成一个 70...100 的"关系健康度分数"，并在首页、关系页、
//  详情页、分析页、Widget 共 5 处展示、3 种档位配色、一句话建议。
//
//  它有三个致命问题：
//   ① **它不度量任何东西。** 分数完全由用户自己输入的亲密度决定，
//      输入一次，输出永远相同。没有打卡率、没有冲突频率、没有对话质量参与运算。
//   ② **下限写死 70，使 `Band.critical` 成为死代码** —— 代码里存在一个
//      永远不会出现的"关系危急"红色档位，说明作者自己也没打算让它表达危机。
//   ③ **它把伪精度做成了产品门面。** 用户看到一个两位数，会默认"有东西在算"。
//      这与本产品刚刚砍掉的「责任百分比 55/45」完全同构。
//
//  删除后保留什么：
//   `intimacyScore` 仍是用户**主动标注**的一个字段（"我和这个人有多近"），
//  它驱动的是纪念日展示、话术语气这类**用户可见的输入语义**，
//  不再是任何"评分"的原料。因此本文件只保留夹取与展示标签，不含换算与档位。
//

import Foundation

enum IntimacyScale {

    static let range: ClosedRange<Int> = 0...10

    /// 把任意输入夹到合法区间。
    ///
    /// 保留原因（修复报告 R6）：旧版 `healthScore` 的 setter 会把
    /// `intimacyScore` 写成 -56 / -194 这类值，存量数据需要一次启动修复。
    static func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// 面向用户的标签。**不是评分，是关系距离的描述**。
    ///
    /// 刻意不用"很好 / 一般 / 差"这类评价词：这个值来自用户自己，
    /// 产品没有立场评价它。
    static func label(for intimacy: Int) -> String {
        switch clamp(intimacy) {
        case 0...2:  return "比较疏远"
        case 3...4:  return "有距离"
        case 5...6:  return "一般"
        case 7...8:  return "比较近"
        default:     return "很近"
        }
    }
}
