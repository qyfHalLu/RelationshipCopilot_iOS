//
//  ProfilesView.swift
//  RelationshipCopilot
//
//  人物关系管理。
//
//  修复报告清单：
//  - A3：关系类型 → 中文映射原先在本文件里手写一份，且**漏了 spouse**（配偶显示成「其他」）。
//        现统一走 `RelationshipType.displayName`。
//  - A1：原 `ProfileCard.healthScore` 复制了一份 `70 + intimacyScore * 3` 公式，
//        与 `Profile.healthScore` 形成两个事实来源。
//        改版后该分数整体删除（见 Core/IntimacyScale.swift），两个事实来源一并消失。
//  - 导航：原代码在 `NavigationLink(value:)` 里又包了一层
//        `NavigationLink(destination:)`（第 32 行与第 150 行），属双层 NavigationLink，
//        点击可能 push 两层。现在只有外层一个。
//  - 头像色：原实现用 `profile.name.hashValue`，而 Swift 的 String.hashValue 带**每进程随机种子**，
//        导致同一个人每次冷启动头像颜色都变。现改为对 UUID 做确定性哈希。
//  - C2：统计卡片原显示硬编码的「82 平均健康度 / 75% 履约率」，
//        与左侧真实的"关系数"混排，用户无法分辨真假。现全部改为真实计算，无数据显示「—」。
//  - 新增删除入口（原先任何页面都删不掉人物）。
//

import SwiftUI
import SwiftData

struct ProfilesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router

    @Query(sort: \Profile.updatedAt, order: .reverse) private var profiles: [Profile]
    @Query private var promises: [Promise]
    @Query private var disputeCases: [DisputeCase]

    @State private var showAddProfile = false
    @State private var pendingDelete: Profile?

    private var overallFulfillment: Double? {
        let entries = promises.flatMap(\.entryProjection)
        guard !entries.isEmpty else { return nil }
        return FulfillmentStats.summarize(entries: entries).rate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    RelationshipStatsCard(
                        profileCount: profiles.count,
                        activeCaseCount: disputeCases.filter { $0.state.isCollecting || $0.state == .ready }.count,
                        fulfillment: overallFulfillment
                    )

                    if profiles.isEmpty {
                        EmptyStateView(
                            icon: "person.2.badge.plus",
                            title: "还没有人物",
                            message: "先添加一个重要的人，之后就能记录对话、追踪承诺。",
                            actionTitle: "添加人物"
                        ) {
                            showAddProfile = true
                        }
                    } else {
                        LazyVStack(spacing: ThemeManager.Spacing.sm) {
                            ForEach(profiles) { profile in
                                NavigationLink {
                                    ProfileDetailView(profile: profile)
                                } label: {
                                    ProfileCard(profile: profile)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDelete = profile
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        AddProfileButton {
                            showAddProfile = true
                        }
                    }
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("关系管理")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddProfile = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加人物")
                }
            }
            .sheet(isPresented: $showAddProfile) {
                AddProfileView()
            }
            .alert(
                "删除「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let profile = pendingDelete { delete(profile) }
                    pendingDelete = nil
                }
            } message: {
                Text("会同时删除这个人的所有承诺与对话记录，无法恢复。")
            }
        }
    }

    private func delete(_ profile: Profile) {
        modelContext.delete(profile)
        do {
            try modelContext.save()
            DataMaintenance.syncWidget(context: modelContext)
        } catch {
            AppLog.persistence.error("Delete profile failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 统计卡片（全部真实数据）

struct RelationshipStatsCard: View {
    let profileCount: Int
    /// 「没说完的评理」件数。替换原来的「平均健康度」——
    /// 那个数字是把用户自己拖的滑块再平均一次，比单个分数更没意义。
    let activeCaseCount: Int
    let fulfillment: Double?

    var body: some View {
        // 三列固定横排在大字号下会被截断（界面审查实测：accessibility-XXXL 时
        // 变成 `2/0/1…` 这类不可读残片，因为 StatItem 用了 minimumScaleFactor）。
        // 改用自适应网格：放不下就自动降为两列 / 单列。
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: ThemeManager.Spacing.md)],
            spacing: ThemeManager.Spacing.md
        ) {
            StatItem(
                icon: "person.2.fill",
                value: "\(profileCount)",
                label: "关系数",
                tint: ThemeManager.Colors.primary
            )
            StatItem(
                icon: "bubble.left.and.text.bubble.right.fill",
                value: activeCaseCount > 0 ? "\(activeCaseCount)" : "—",
                label: "没说完",
                tint: ThemeManager.Colors.accent1
            )
            StatItem(
                icon: "checkmark.circle.fill",
                value: fulfillment.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                label: "履约率",
                tint: ThemeManager.Colors.accent
            )
        }
        .padding(ThemeManager.Spacing.lg)
        .surfaceCard()
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: ThemeManager.Spacing.xs) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            // 不用 minimumScaleFactor：它把「放不下」伪装成字重问题，
            // 结果是字号越大、内容越看不见。允许折行，让容器去适应内容。
            Text(value)
                .font(ThemeManager.Typography.title2)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }
}

// MARK: - 人物卡片

struct ProfileCard: View {
    let profile: Profile

    /// 确定性头像色：基于 UUID 而非 `hashValue`。
    /// `String.hashValue` 每个进程种子不同，会导致头像颜色每次启动都变。
    private var avatarColor: Color {
        let palette: [Color] = [
            ThemeManager.Colors.primary,
            ThemeManager.Colors.accent1,
            ThemeManager.Colors.accent2,
            ThemeManager.Colors.accent3,
            ThemeManager.Colors.accent4
        ]
        var hash: UInt64 = 1469598103934665603   // FNV-1a 偏移
        for byte in profile.id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private var initials: String {
        String(profile.name.prefix(1))
    }

    /// 头像直径随笔号语义缩放，与内部的 `.title3` 同源。
    ///
    /// 原先硬编码 52pt、字号却是会放大的 `.title3`：
    /// XXXL 下一个汉字就宽过圆，首字被圆裁掉两侧。
    /// 这和 `TestimonyEditor` 的题号徽章是同一类缺陷——**框是常量、字是变量**。
    @ScaledMetric(relativeTo: .title3) private var avatarDiameter: CGFloat = 52

    var body: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.15))
                    .frame(width: avatarDiameter, height: avatarDiameter)
                Text(initials)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(avatarColor)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)

                Text(profile.relationship.displayName)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)

                if let last = profile.lastInteractionAt {
                    Text("最近记录 \(AppFormatters.relativeText(for: last))")
                        .font(.caption2)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            }

            Spacer()

            // 原为一串两位数健康分。现在换成用户自己标注的距离感标签 ——
            // 没有数字，也就没有"看起来像测量值"的暗示。
            Text(profile.intimacyLabel)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ThemeManager.Colors.surfaceElevated)
                .clipShape(Capsule())

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(profile.name)，\(profile.relationship.displayName)，距离\(profile.intimacyLabel)"
        )
    }
}

// MARK: - 添加按钮

struct AddProfileButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("添加人物", systemImage: "plus")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ThemeManager.Spacing.md)
                .background(ThemeManager.Colors.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 统一空状态
//
// 修复报告 C8：原三个页面各有一套空状态实现（`EmptyStateView` / `EmptyPromiseView` /
// `EmptyHistoryView`），且都没有主按钮。现在统一为一个带 CTA 的组件。

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: icon)
                .font(.system(.largeTitle, design: .rounded))
                .foregroundStyle(ThemeManager.Colors.textSecondary.opacity(0.6))

            Text(title)
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text(message)
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(ThemeManager.Typography.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ThemeManager.Spacing.sm)
                        .background(ThemeManager.Colors.primary)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(ThemeManager.Spacing.xl)
        .surfaceCard()
    }
}
