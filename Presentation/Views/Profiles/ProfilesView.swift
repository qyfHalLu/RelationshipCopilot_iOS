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

    /// 网格最小列宽。随笔号缩放，理由见 `body` 里的注释。
    ///
    /// 数值经过实测校准，不是随手取的：
    ///  · 常规字号下三列要能并排（屏幕宽 402 - 左右内边距 32 - 卡片内边距 48 ≈ 322，
    ///    三列 + 两个间距 ≈ 单列 100pt），取 96 正好放下三列。
    ///  · XXXL 下 `title2` 放大约 2.4 倍，96 同比到 230，
    ///    322pt 只放得下一列 —— 这是**有意的**：宁可单列，
    ///    也不能把「100%」拆成两行（截图实测过的那种残片）。
    @ScaledMetric(relativeTo: .title2) private var minColumnWidth: CGFloat = 96

    var body: some View {
        // 三列固定横排在大字号下会被截断（界面审查实测：accessibility-XXXL 时
        // 变成 `2/0/1…` 这类不可读残片，因为 StatItem 用了 minimumScaleFactor）。
        // 改用自适应网格：放不下就自动降为两列 / 单列。
        //
        // 最小列宽必须**随笔号放大**：写死 96pt 时，XXXL 下字的实际宽度已经
        // 超过 96pt，但网格仍按 96pt 算"放得下三列"，于是挤成
        // 「100」+「%」两行（截图实测）。改成 @ScaledMetric 后，
        // 大字号下每列最小宽度同比变大，网格会自动降到两列或单列。
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minColumnWidth), spacing: ThemeManager.Spacing.md)],
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 大字号下改为**横排**：图标 | 数值 + 标签。
        //
        // ## 为什么必须换方向
        //
        // 竖排（图标在上、数值在中、标签在下）三行叠起来，在 XXXL 下
        // 单张卡片就占满整屏 —— 截图实测：统计卡片把两条人物档案全部挤出屏幕，
        // 用户打开关系管理**看不到任何人**。
        // 单测和"渲染出来了"类断言全都通过，因为每段文字确实都在。
        //
        // 横排后高度降到原来的约 1/3，三条统计能完整留在首屏上半部分。
        if dynamicTypeSize.isAccessibilitySize {
            HStack(spacing: ThemeManager.Spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    valueText
                    labelText
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) \(value)")
        } else {
            VStack(spacing: ThemeManager.Spacing.xs) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                valueText
                labelText
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) \(value)")
        }
    }

    /// `value` 是「2」「—」「100%」这类**短符号串**，数字和 % 是一个整体。
    ///
    /// 允许它折行的后果已在 XXXL 截图里实测到：「100%」被断成「100」+「%」，
    /// 读起来像两个不同的量。所以必须禁止换行 —— 与 label 相反：
    /// label 是中文短语，大字号下折行仍读得通，而数值符号串折行就是错误。
    ///
    /// 仍不用 minimumScaleFactor：靠在父层自适应列数 / 横排布局给它让出宽度。
    private var valueText: some View {
        Text(value)
            .font(ThemeManager.Typography.title2)
            .foregroundStyle(ThemeManager.Colors.textPrimary)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var labelText: some View {
        Text(label)
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 人物卡片

struct ProfileCard: View {
    let profile: Profile

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 头像直径随笔号语义缩放。
    ///
    /// 原先硬编码 52pt、字号却是会放大的 `.title3`：
    /// XXXL 下一个汉字就宽过圆，首字被圆裁掉两侧。
    /// 这和 `TestimonyEditor` 的题号徽章是同一类缺陷——**框是常量、字是变量**。
    /// 现在交给 `AvatarCircle` 按直径比例算字号，圆和字是同一比例。
    @ScaledMetric(relativeTo: .title3) private var avatarDiameter: CGFloat = 52

    /// 辅助功能字号下改为上下排布。
    ///
    /// ## 为什么必须换布局，而不是"让它挤一挤"
    ///
    /// 原布局是固定 HStack：头像 + 名字列 + Spacer + 距离胶囊 + 箭头。
    /// XXXL 下每个元素的**字号**都放大了，但间距和头像的**横向占比**没变，
    /// 于是名字列被压到只剩一个字宽 —— 截图实测的后果是：
    ///   · 「妈妈」竖排成「妈」/「妈」两行
    ///   · 「有距离」竖排成「有」/「距」/「离」一列
    /// 单测和 UI 断言**全部通过**，因为这确实是"渲染出来了"，
    /// 只是渲染成了一列竖字。只有看图才能发现。
    ///
    /// 换布局的判断依据用 `dynamicTypeSize.isAccessibilitySize`，
    /// 而不是去量宽度：宽度判断依赖具体机型，而这个缺陷的本质是字号档位。
    private var isAccessibilitySize: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var intimacyBadge: some View {
        // 原为一串两位数健康分。现在换成用户自己标注的距离感标签 ——
        // 没有数字，也就没有"看起来像测量值"的暗示。
        Text(profile.intimacyLabel)
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            // 三个字的标签不许被压成一列竖字。
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ThemeManager.Colors.surfaceElevated)
            .clipShape(Capsule())
    }

    var body: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            // 颜色/照片的唯一真相来源。
            //
            // 原来这里是自己用 UUID 哈希算颜色，**完全不读 `profile.avatar`** ——
            // 用户在添加页选的色保存后从来没生效过。现在统一走 `AvatarCircle`，
            // 它内部解析 `avatar`，解析不出来才回退到 UUID 派生色。
            AvatarCircle(
                name: profile.name,
                raw: profile.avatar,
                fallbackID: profile.id,
                diameter: avatarDiameter
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    // 名字是短词，永远不该折行。折了就把「妈妈」显示成两行。
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                // 用 `relationshipLabel` 而不是 `relationship.displayName`：
                // 后者永远显示枚举的「其他」，把用户填的自定义名称吞掉了。
                Text(profile.relationshipLabel)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                if isAccessibilitySize {
                    // 大字号：胶囊挪到名字下面，横向空间全留给文字。
                    intimacyBadge
                        .padding(.top, 2)
                }

                if let last = profile.lastInteractionAt {
                    Text("最近记录 \(AppFormatters.relativeText(for: last))")
                        .font(.caption2)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            }
            // 让名字列在还有余量时优先占据空间，而不是被右侧挤掉。
            .layoutPriority(1)

            Spacer(minLength: 0)

            if !isAccessibilitySize {
                intimacyBadge
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .accessibilityElement(children: .combine)
        // 必须用 `relationshipLabel`，与上面可见文本保持一致。
        // 这里原先写的是 `relationship.displayName`：`.accessibilityElement(children: .combine)`
        // 会**丢弃**内部 Text 的可访问性文本、只保留这一条 label，
        // 于是肉眼看到「母女」、VoiceOver 读出的却是「其他」——
        // 用户自填的关系名对读屏用户等于不存在。
        .accessibilityLabel(
            "\(profile.name)，\(profile.relationshipLabel)，距离\(profile.intimacyLabel)"
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
