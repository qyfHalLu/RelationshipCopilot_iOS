//
//  DataEraser.swift
//  RelationshipCopilot
//
//  「删除全部本地数据」的唯一实现。
//
//  ## 为什么要有这个文件
//
//  这里曾经有一个真实的隐私缺陷：`MeView.deleteEverything()` 手写了一份删除清单，
//  而 Schema 里注册了 6 个 `@Model` 实体，清单里只有 5 个 —— **`DisputeCase` 被漏掉了**。
//  后果是用户连点两次确认、看到「已删除全部本地数据」之后，
//  全部评理证词（`hurtMost` 里写着"最让你难受的是…"，可能还含自伤/暴力描述）
//  仍然完整躺在 SQLite 里。
//
//  对一个核心承诺是「数据只存本机、涉及隐私」的产品，这不是体验问题，是**承诺失效**。
//
//  ## 为什么不用反射遍历 Schema 自动删除
//
//  SwiftData 的 `ModelContext.delete(model:)` 是泛型方法，要求静态类型，
//  无法用 `any PersistentModel.Type` 的哨兵值调用（existential 不能直接绑定到
//  受协议约束的泛型参数）。所以「一行删干净」在这个框架下做不到。
//
//  退而求其次的正确做法，是把**唯一事实来源**收敛到一处：
//    · `modelTypes` 同时驱动 Schema 注册与删除逻辑
//    · `Tests` 里断言 `modelTypes` 与 `Schema.entities` 完全一致
//  新增 `@Model` 时若忘了加进来，**测试会失败**，而不是静默漏删。
//

import Foundation
import SwiftData

enum DataEraser {

    /// 全部 `@Model` 实体的**唯一清单**。
    ///
    /// Schema 注册与 `eraseAll` 都从它派生，两者不可能再出现分歧。
    /// 顺序无关，但删除顺序有讲究，见 `eraseAll`。
    static let modelTypes: [any PersistentModel.Type] = [
        User.self,
        Profile.self,
        Promise.self,
        FulfillmentRecord.self,
        RecordingSession.self,
        DisputeCase.self
    ]

    /// 清空所有本地数据。
    ///
    /// ## 删除顺序不是随意的
    ///
    /// 从「叶子」到「根」：先删挂着别人的，再删被挂的。
    /// `DisputeCase` / `RecordingSession` / `Promise` 都持有 `Profile` 引用。
    ///
    /// 这个顺序是**实测出来的，不是猜的**：把 `DisputeCase` 那一行去掉再跑删除，
    /// App 会直接崩溃（`com.relationshipcopilot.app crashed`），
    /// 而不是"安静地少删一张表"。也就是说，当初那个漏删缺陷的后果
    /// 比"隐私数据残留"更严重 —— 用户点「永久删除」会闪退。
    @MainActor
    static func eraseAll(in context: ModelContext) throws {
        // 叶子
        try context.delete(model: FulfillmentRecord.self)
        try context.delete(model: DisputeCase.self)
        try context.delete(model: RecordingSession.self)
        try context.delete(model: Promise.self)
        // 根
        try context.delete(model: Profile.self)
        try context.delete(model: User.self)
        try context.save()
    }

}
