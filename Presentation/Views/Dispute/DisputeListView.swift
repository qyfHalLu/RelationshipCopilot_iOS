//
//  DisputeListView.swift
//  RelationshipCopilot
//
//  案卷列表 + 新建入口。
//
//  刻意**不做**"历史判例库"式的列表（参考产品有）。
//  理由：把过去每次都摆出来，会让人开始统计"谁赢得多"，
//  而这正是本产品明确不生产的东西。列表只承担"找回上次没说完的那件事"。
//

import SwiftUI
import SwiftData

struct DisputeListView: View {

    /// 这一屏要不要自己建 `NavigationStack`。
    ///
    /// ## 为什么必须区分（一个"点进去又退出来"的真实缺陷）
    ///
    /// 这个视图有两个入口：
    ///   1. 底部 tab 的「评理」—— 它是 tab 根页，**没有人替它建导航容器**，
    ///      所以必须自己包一层；
    ///   2. 首页「把一件事说清」卡片 —— 那里是 `NavigationLink` push 进来的，
    ///      已经在 `HomeView` 的 `NavigationStack` 里了。
    ///
    /// 原来两种入口都无条件包 `NavigationStack`，于是第 2 种变成**栈套栈**。
    /// 症状就是用户报的：点一下有时候没反应、有时候进去了又自己弹回来，
    /// 得再点一次才进得去。
    ///
    /// 这个缺陷很难靠断言抓：`NavigationStack` 嵌套在 SwiftUI 里不报错、
    /// 不警告，push 失败也只表现为"什么都没发生"。所以判据只能是结构本身。
    var ownsNavigationStack: Bool = true

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DisputeCase.updatedAt, order: .reverse) private var cases: [DisputeCase]
    @Query(sort: \Profile.updatedAt, order: .reverse) private var profiles: [Profile]

    @State private var showNewCase = false
    /// 用 `UUID` 而不是 `DisputeCase` 作为导航值：
    /// 对象被删除后路径里仍会留着它，SwiftData 会读到一个已失效的模型。
    @State private var path: [UUID] = []

    /// 待确认删除的案卷（nil 表示没有待确认的操作）。
    @State private var pendingDeletion: DisputeCase?
    /// 删除成功后的触感触发器。
    @State private var deletionFeedback = 0

    var body: some View {
        if ownsNavigationStack {
            NavigationStack(path: $path) { content }
        } else {
            content
        }
    }

    private var content: some View {
        ZStack {
            ThemeManager.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.lg) {

                    introCard

                    if cases.isEmpty {
                        emptyState
                    } else {
                        caseList
                    }
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
                // 底部留白：iOS 26 起 tab bar 是浮在内容之上的，
                // 滚动到末尾时最后一卡需要能完全浮出它。
                .padding(.bottom, ThemeManager.Spacing.xxl)
            }
            .refreshable { /* 本地数据，无网络刷新 */ }
        }
        .navigationTitle("评理")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: UUID.self) { id in
            if let item = cases.first(where: { $0.id == id }) {
                DisputeFlowView(disputeCase: item)
            } else {
                Text("这件已经不在了。")
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewCase = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("开一件新的")
            }
        }
        .sheet(isPresented: $showNewCase) {
            NewDisputeSheet(profiles: profiles)
        }
        // 删单件必须二次确认：案卷里是双方写下的原文，删了不可恢复。
        // 「删除全部数据」那页都有两道确认，单件删除没有确认是不一致的。
        .confirmationDialog(
            "删除这件评理？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("双方写的原文会一起删掉，无法恢复。")
        }
        .sensoryFeedback(.warning, trigger: deletionFeedback)
        .task {
            #if DEBUG
            // 界面核验：直接推入指定案卷，省去用脚本点进列表。
            // 只在自建栈时有效 —— 被 push 进来时路径归父栈管，写这里是空操作。
            if ownsNavigationStack,
               let id = UITestSupport.initialCaseID,
               cases.contains(where: { $0.id == id }) {
                path = [id]
            }
            #endif
        }
    }

    // MARK: 说明卡
    //
    // 这一屏是新用户理解「这不是判官」的唯一机会，所以说明必须前置，
    // 不能塞进设置页或帮助文档。

    private var introCard: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("这里不判谁对谁错")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                bullet("两个人各写一份，互相看不到对方写的。")
                bullet("第三方会告诉你们：你们其实在争两件事、各自想被听见什么、卡在哪。")
                bullet("它不会给你们打分，也不会说谁该道歉。")
            }

            Text("研究发现，关系里约 69% 的冲突源自性格差异，本来就不会消失。所以有些事我们不给解决方案，只给一个能长期共处的说法。")
                .font(ThemeManager.Typography.footnote)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .padding(ThemeManager.Spacing.lg)
        .surfaceCard()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
            Circle()
                .fill(ThemeManager.Colors.primary)
                .frame(width: 5, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Text(text)
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(.title, design: .rounded))
                .foregroundStyle(ThemeManager.Colors.primary)
                .accessibilityHidden(true)

            Text("还没有开过")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text("下一次说不清的时候，来这里各写一份。")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showNewCase = true
            } label: {
                Text("现在开一件")
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(ThemeManager.Colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(ThemeManager.Spacing.lg)
        .frame(maxWidth: .infinity)
        .surfaceCard()
    }

    // MARK: 列表

    private var caseList: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("进行过的")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            VStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(cases) { item in
                    NavigationLink(value: item.id) {
                        DisputeCaseRow(disputeCase: item)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            requestDelete(item)
                        } label: {
                            Label("删除这件", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    /// 待确认删除的案卷。
    ///
    /// 原先长按菜单点「删除这件」是**立即生效、无法撤销**的：
    /// 一次误触就永久丢掉整份评理（含双方写的全部私密证词）。
    /// 删除全部数据那页都有两道确认，删单件反而没有 —— 这是不一致的。
    private func requestDelete(_ item: DisputeCase) {
        pendingDeletion = item
    }

    private func confirmDelete() {
        guard let item = pendingDeletion else { return }
        pendingDeletion = nil
        modelContext.delete(item)
        do {
            try modelContext.save()
            deletionFeedback += 1
        } catch {
            AppLog.persistence.error("Delete dispute failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 单行

struct DisputeCaseRow: View {
    let disputeCase: DisputeCase

    var body: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .accessibilityElement(children: .combine)
    }

    /// 列表里显示的标题。
    ///
    /// ## 为什么未完成的案卷不能显示真实标题
    ///
    /// `DisputeCase.title` 是从 A 方第一题「发生了什么」的首句截取前 18 字得来的
    /// （见 `DisputeCase.suggestedTitle`）。也就是说，**标题里就带着 A 的陈述**。
    ///
    /// 而这一屏是会被 B 看到的：A 写完点「TA 已经拿到了」把手机递过去，
    /// B 只要侧滑或点返回回到列表，就能读到 A 写的那句话。
    /// 交接页明确写着「你写的那一份已经收起来了，屏幕上不会显示」——
    /// 这句话在列表页不成立。**密封承诺在实现层是破的。**
    ///
    /// 所以：只要还没到 B 提交完成（`collectingB` / `waitingForB`），
    /// 一律用中性标题，不泄露任何一方写的内容。
    /// 完成之后（`ready` 及以后）双方都看得到全部内容，标题可以正常显示。
    private var displayTitle: String {
        switch disputeCase.state {
        case .collectingB, .waitingForB:
            return "一次还没写完的"
        default:
            return disputeCase.title
        }
    }

    private var subtitle: String {
        let who = disputeCase.profile?.name
        let status = disputeCase.statusSummary
        let time = AppFormatters.relativeText(for: disputeCase.updatedAt)
        if let who, !who.isEmpty {
            return "\(who) · \(status) · \(time)"
        }
        return "\(status) · \(time)"
    }

    private var iconName: String {
        if disputeCase.isBlocked { return "shield.lefthalf.filled" }
        switch disputeCase.state {
        case .closed: return "checkmark.bubble.fill"
        case .ready:  return "eye.fill"
        default:      return "square.and.pencil"
        }
    }

    private var tint: Color {
        if disputeCase.isBlocked { return ThemeManager.Colors.danger }
        switch disputeCase.state {
        case .closed: return ThemeManager.Colors.secondary
        case .ready:  return ThemeManager.Colors.accent
        default:      return ThemeManager.Colors.primary
        }
    }
}

// MARK: - 新建

struct NewDisputeSheet: View {

    let profiles: [Profile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMode: DisputeMode = .sameDevice
    @State private var selectedProfileID: UUID?
    @State private var createdCase: DisputeCase?
    @State private var goToFlow = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.xl) {

                    modeSection
                    profileSection
                    privacyNote

                    Button(action: create) {
                        Text("开始")
                            .font(ThemeManager.Typography.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(ThemeManager.Colors.primary)
                            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("开一件新的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $goToFlow) {
                if let createdCase {
                    DisputeFlowView(disputeCase: createdCase)
                }
            }
        }
    }

    // MARK: 模式选择

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("这次是几个人写？")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            modeCard(
                mode: .sameDevice,
                title: "两个人一起",
                detail: "同一台手机上各写一份，互相看不到对方写的内容。写完一起看结果。",
                icon: "person.2.fill"
            )

            // ## 远程模式此前在界面上**根本不存在**
            //
            // `DisputeMode.remote`、邀请链接、加密回传、`RemoteHandoverView`
            // 全都实现好了，但新建入口只有「同一台手机」和「只有我自己」两项 ——
            // 于是第三方填写的链路只有 UI 测试的启动参数能走到，真实用户永远看不见。
            // 用户的原话是："如果是两个人的话，还显示要在同一部手机上输入"。
            //
            // 这一项是它唯一的入口，删掉等于整条远程链路变成死代码。
            modeCard(
                mode: .remote,
                title: "各自在自己的手机上",
                detail: "你写完会得到一个链接，发给 TA，TA 在自己手机上写。写完两边都能看结果。",
                icon: "paperplane.fill"
            )

            modeCard(
                mode: .solo,
                title: "只有我自己",
                detail: "把这件事理清楚。它不会假装知道对方怎么想，也不会说谁对谁错。",
                icon: "person.fill"
            )
        }
    }

    private func modeCard(mode: DisputeMode, title: String, detail: String, icon: String) -> some View {
        let isSelected = selectedMode == mode
        return Button {
            selectedMode = mode
        } label: {
            HStack(alignment: .top, spacing: ThemeManager.Spacing.md) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(isSelected ? .white : ThemeManager.Colors.primary)
                    .frame(width: 38, height: 38)
                    .background(isSelected ? ThemeManager.Colors.primary : ThemeManager.Colors.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(ThemeManager.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                    Text(detail)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ThemeManager.Colors.primary : ThemeManager.Colors.border)
                    .accessibilityHidden(true)
            }
            .padding(ThemeManager.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ThemeManager.Colors.primary.opacity(0.06) : ThemeManager.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous)
                    .strokeBorder(
                        isSelected ? ThemeManager.Colors.primary : ThemeManager.Colors.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 对象

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("关于谁")
                .font(ThemeManager.Typography.headline)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            if profiles.isEmpty {
                Text("还没有人物档案。可以先直接开始，之后在「关系」里补上。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        ForEach(profiles) { profile in
                            profileChip(profile)
                        }
                    }
                }
            }
        }
    }

    private func profileChip(_ profile: Profile) -> some View {
        let isSelected = selectedProfileID == profile.id
        return Button {
            selectedProfileID = isSelected ? nil : profile.id
        } label: {
            Text(profile.name)
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(isSelected ? .white : ThemeManager.Colors.textPrimary)
                .padding(.horizontal, ThemeManager.Spacing.md)
                .frame(minHeight: 40)
                .background(isSelected ? ThemeManager.Colors.primary : ThemeManager.Colors.surfaceElevated)
                .clipShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 隐私说明
    //
    // 这段文案不是免责声明，是**产品诚实性的一部分**。
    // 见 DisputeMode.sameDevice 的注释：密封只能是界面级，必须明说。

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Label("关于隐私", systemImage: "lock.shield")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            Text(privacyBody)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .padding(ThemeManager.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeManager.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
    }

    private var privacyBody: String {
        switch selectedMode {
        case .sameDevice:
            return "两份内容都只存在这台手机上，不会上传到我们的服务器。生成结果时会发给模型服务一次，之后就留在本地。\n\n「互相看不到」是界面上的约定：对方写的时候，屏幕上不会显示你写的内容。但这不是加密保证——如果对方刻意翻找这台手机，技术上仍可能看到。"
        case .remote:
            // ## 这一段必须写得比别的都仔细
            //
            // 远程模式是唯一一处**数据真的离开手机**的地方。
            // 说得含糊，等于拿 "端到端加密" 这种词去换用户的信任 ——
            // 而这个产品在别处（MeView / 录音页 / Info.plist）都写着"数据仅存本机"，
            // 那几句话在这一模式下**不再成立**，必须在这里说清。
            //
            // 同时不能承诺做不到的事：明文最终会落到发起方的手机上，
            // 那台手机的安全性是另一回事。所以只说"传输与存储中是密文"，
            // 不说"绝对安全"。
            return "你写的内容只存在这台手机上。TA 在自己设备上写的那份，会用一次性密钥加密后才经过服务器——服务器存的是打不开的密文，看不到内容。\n\n生成结果时会发给模型服务一次，之后就留在本地。\n\n说明：这是唯一会把内容传到本机之外的模式。放弃这种模式、改用「同一台手机」，内容就完全不出设备。"
        case .solo:
            return "内容只存在这台手机上，不会上传到我们的服务器。生成结果时会发给模型服务一次，之后就留在本地。"
        }
    }

    // MARK: 创建

    private func create() {
        let newCase = DisputeCase(title: DisputeCase.defaultTitle, mode: selectedMode)
        if let id = selectedProfileID {
            newCase.profile = profiles.first { $0.id == id }
        }
        modelContext.insert(newCase)
        do {
            try modelContext.save()
            createdCase = newCase
            goToFlow = true
            Telemetry.shared.track(.disputeStarted)
        } catch {
            AppLog.persistence.error("New dispute save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
