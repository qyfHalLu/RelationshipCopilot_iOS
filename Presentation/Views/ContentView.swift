import SwiftUI
import SwiftData

// MARK: - 根视图
//
// 修复报告 A（App 入口）：
//  - 原 `RelationshipCopilotApp` 在 `WindowGroup` 的 body 里直接 `AuthenticationService()`，
//    body 每次重新求值都会**新建一个服务实例**，登录态会丢。现改为在 App 层持有单例。
//  - 原 `ContentView` 只有一个 Group 无启动自检；现在启动后执行 `DataMaintenance`。

struct ContentView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.modelContext) private var modelContext

    @State private var router = AppRouter()
    @State private var didRunMaintenance = false

    var body: some View {
        Group {
            if authService.isRestoring {
                LaunchPlaceholder()
            } else if authService.isAuthenticated {
                MainTabView()
                    .environment(router)
                    .transition(.opacity)
            } else {
                AuthenticationView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: authService.isAuthenticated)
        .animation(.smooth(duration: 0.25), value: authService.isRestoring)
        #if DEBUG
        // 字号档位由 App 自己设定（见 `UITestSupport.forcedDynamicTypeSize`）。
        // 不用 `simctl ui content_size`：那会改模拟器的持久状态、跑完不还原，
        // 于是"上一次跑过 XXXL"就成了隐式前置条件，档位设错时用例会静默假绿。
        // 只在显式传参时才覆盖，否则服从系统设置（手动调试不受影响）。
        .modifier(ForcedDynamicTypeModifier())
        .overlay(alignment: .topLeading) { FontProbe() }
        .overlay(alignment: .topLeading) { AppearanceProbe() }
        #endif
        .task {
            #if DEBUG
            // 界面核验入口（仅 DEBUG，见 UITestSupport）
            if UITestSupport.shouldClearAuth {
                authService.logout()
            }
            if UITestSupport.shouldAutoLogin {
                authService.debugForceLogin()
            }
            if UITestSupport.shouldSeed {
                UITestSupport.seedIfNeeded(context: modelContext)
            }
            if let tab = UITestSupport.initialTab {
                router.selectedTab = tab
            }
            #endif

            await authService.restoreSessionIfNeeded()
            Telemetry.shared.trackLaunch()
            guard !didRunMaintenance else { return }
            didRunMaintenance = true
            DataMaintenance.run(context: modelContext)
        }
    }
}

/// 启动占位：避免"先闪一下登录页再跳进首页"。
private struct LaunchPlaceholder: View {
    var body: some View {
        ZStack {
            ThemeManager.Colors.background.ignoresSafeArea()
            ProgressView()
                .accessibilityLabel("正在载入")
        }
    }
}

#if DEBUG
/// 只在显式传 `--ui-test-font=` 时覆盖动态字体档位。
///
/// 用 ViewModifier 而不是直接 `.dynamicTypeSize(... ?? .large)`：
/// 后者在没有传参时也会把字号**钉死在 .large**，
/// 从而让"用户把系统字号调大"这个真实场景永久失效 —— 测试设施不得改变产品行为。
private struct ForcedDynamicTypeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if let size = UITestSupport.forcedDynamicTypeSize {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}

/// 把**实际生效**的字号档位暴露给测试。
///
/// 存在的理由只有一个：让"跑在普通字号上却声称测了 XXXL"这种假绿无法通过。
///
/// 注意**不能**用 `.foregroundStyle(.clear)` 隐藏：XCUITest 会把完全透明的元素
/// 判定为不可见，`staticTexts["..."]` 查不到，探针本身就成了假绿来源。
/// 改用 1pt 字号 + 贴到左上角，人眼几乎看不见，但它在可访问性树里是正常元素。
private struct FontProbe: View {
    var body: some View {
        Text(verbatim: "fontprobe:\(UITestSupport.fontProbeLabel)")
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityIdentifier("uitest.font.probe")
            .allowsHitTesting(false)
    }
}

/// 把**实际生效**的深浅色暴露给测试。
///
/// ## 为什么需要和字号探针一样的东西
///
/// 深色模式测试原本只断言"某个标题文字存在"。那句话在浅色模式下同样存在 ——
/// 所以一旦 `-appearanceMode dark` 没有生效（参数名改了、`@AppStorage`
/// 换了 key、修饰符顺序变了），用例**照样全绿**，截出来的却是白底图。
///
/// 这和字号那次假绿是同一个形状：断言度量的不是它声称要度量的那个维度。
/// 字体那次靠 `fontprobe` 治好了；深浅色当时没做，于是留下同一个洞。
///
/// 探针读 `@Environment(\.colorScheme)` —— 即渲染时真正生效的值，
/// 而不是"我传了什么参数"。
private struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(verbatim: "schemeprobe:\(scheme == .dark ? "dark" : "light")")
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .clipped()
            .accessibilityIdentifier("uitest.scheme.probe")
            .allowsHitTesting(false)
    }
}
#endif

// MARK: - 路由
//
// 修复报告 C5：原 `MainTabView` 用局部 `selectedTab`，首页的"去查看"等跨 tab 跳转
// 只能写成空动作。现在用共享路由。

@Observable
final class AppRouter {
    /// 一级入口。改版后「评理」升为 tab，「记录」降为首页入口 ——
    /// 产品重心从"录音分析"转到"两个人把话说清"，
    /// 录音是评理之外的补充手段，不该继续占一个一级位置。
    enum Tab: Int, CaseIterable {
        case home, disputes, profiles, promises, me
    }

    var selectedTab: Tab = .home

    /// 待展开的页面（用于从通知/Widget 深链）。
    var pendingDeepLink: DeepLink?

    enum DeepLink: Equatable {
        case promise(UUID)
        case session(UUID)
        case dispute(UUID)
    }

    func switchTo(_ tab: Tab) {
        selectedTab = tab
    }
}

// MARK: - 主标签页
//
// 修复报告 C5（P1）：
//  - 原来有 6 个 tab（tag 0,1,2,3,4,6），iPhone 上 `UITabBarController` 只显示前 4 项 + More，
//    因此「快速工具」和「分析报告」**同时**被折进 More，6 个一级入口实际只有 4 个可见。
//  - 固定 5 个。改版后为：首页 / 评理 / 关系 / 承诺 / 我的。
//    录音从一级 tab 移到首页入口（与快速工具、分析报告同层）。

struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(AppRouter.Tab.home)

            DisputeListView()
                .tabItem { Label("评理", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(AppRouter.Tab.disputes)

            ProfilesView()
                .tabItem { Label("关系", systemImage: "person.2.fill") }
                .tag(AppRouter.Tab.profiles)

            PromisesView()
                .tabItem { Label("承诺", systemImage: "checklist") }
                .tag(AppRouter.Tab.promises)

            MeView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppRouter.Tab.me)
        }
        .tint(ThemeManager.Colors.primary)
    }
}

// MARK: - 首页

struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Profile.updatedAt, order: .reverse) private var profiles: [Profile]
    @Query(sort: \Promise.committedAt, order: .reverse) private var promises: [Promise]
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]
    @Query private var disputeCases: [DisputeCase]

    @State private var showAddProfile = false

    /// 还没走完的案子（同机模式写到一半、或已就绪未查看）。
    private var activeCaseCount: Int {
        disputeCases.filter { $0.state.isCollecting || $0.state == .ready }.count
    }

    private var openPromises: [Promise] {
        promises.filter { $0.isOpen }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: ThemeManager.Spacing.lg) {
                        if profiles.isEmpty {
                            // 修复 C1/C8：空状态给引导 + 主 CTA，不展示任何分数
                            HomeEmptyState { showAddProfile = true }
                        } else {
                            DisputeEntryCard(profileCount: profiles.count, activeCaseCount: activeCaseCount)
                        }

                        // 首页信息层级按**产品定位**排，不按功能新旧排：
                        //   ① 评理     —— 主线，最上、最大视觉权重
                        //   ② 待办承诺 —— 评理结果的落地闭环（判决→承诺→打卡）
                        //   ③ 快速工具 —— 保留（含吵架复盘），降为工具位
                        //   ④ 对话分析 —— 录音/历史合并，历史功能收在最后一屏
                        //
                        // 之前是 6 个并列区块（评理、快速工具、承诺、录音、最近、分析），
                        // 新用户打开后看不出主路径在哪；现在 4 块，主线自然浮出。
                        PendingPromisesSection(
                            promises: openPromises,
                            onCheckIn: handleCheckIn,
                            onUndoCheckIn: handleUndoCheckIn,
                            onBackfillCheckIn: handleBackfillCheckIn
                        )
                            .id(HomeAnchor.promises)

                        QuickToolsSection()
                            .id(HomeAnchor.quickTools)

                        DialogueAnalysisSection(sessions: Array(sessions.prefix(3)))
                            .id(HomeAnchor.analysis)
                    }
                    .padding(.horizontal, ThemeManager.Spacing.md)
                    .padding(.vertical, ThemeManager.Spacing.lg)
                    // 底部留白：iOS 26 起 tab bar 是**浮在内容之上**的，
                    // 所以滚动到末尾时最后一张卡片要能完全浮出它。
                    //
                    // 实测（iPhone 17 / iOS 27，UITest 打印真实几何）：
                    // 滚到底时最后一行底边 703、tab bar 顶边 791，余量 88pt。
                    // 48pt 的 xxl 加上 ScrollView 自身的 safeAreaInset 刚好够用。
                    // 若将来调小这个值，`test_home_bottom_clearance` 会立刻失败。
                    .padding(.bottom, ThemeManager.Spacing.xxl)
                }
                .background(ThemeManager.Colors.background)
                #if DEBUG
                // 界面核验用：精确滚到某个区块。
                // 靠 XCUITest 模拟拖拽去"滚到大字号下的某个区块"极不可靠，
                // 拖拽惯性会一次跨过整段内容，于是断言永远找不到目标。
                .task {
                    if let anchor = UITestSupport.initialAnchor.flatMap(HomeAnchor.init(rawValue:)) {
                        // 等首帧布局完成再滚，否则 anchor 还没进视图树。
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
                #endif
                .navigationTitle("关系副驾")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                }
                .sheet(isPresented: $showAddProfile) {
                    AddProfileView()
                }
                .refreshable {
                    DataMaintenance.run(context: modelContext)
                }
            }
        }
    }

    /// 撤销今天的打卡。
    ///
    /// 存在的理由：打卡是一点即生效的，误触必然发生，而连续天数是核心激励。
    /// 没有这一条时，误点「没做到」会让连续记录当场断掉且无法补救。
    private func handleUndoCheckIn(_ promise: Promise) {
        guard promise.removeCheckIn(in: modelContext, calendar: .current) else { return }
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.error("Undo check-in failed: \(error.localizedDescription, privacy: .public)")
        }
        DataMaintenance.syncWidget(context: modelContext)
    }

    /// 补打昨天。
    ///
    /// 只接受"昨天"这一个日期：开放任意日期等于允许补造历史，
    /// 连续天数就失去可信度。这个边界放在调用处而不是 UI 里，
    /// 是因为 UI 可以被绕过（比如将来的捷径/小组件），数据入口不能。
    private func handleBackfillCheckIn(_ promise: Promise, day: Date, status: FulfillmentStatus) {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        guard calendar.startOfDay(for: day) == calendar.startOfDay(for: yesterday) else {
            AppLog.persistence.error("Backfill rejected: only yesterday is allowed")
            return
        }
        promise.recordCheckIn(on: day, status: status, in: modelContext, calendar: calendar)
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.error("Backfill save failed: \(error.localizedDescription, privacy: .public)")
        }
        DataMaintenance.syncWidget(context: modelContext)
    }

    private func handleCheckIn(_ promise: Promise, status: FulfillmentStatus) {
        promise.recordCheckIn(status: status, in: modelContext, calendar: .current)
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.error("Check-in save failed: \(error.localizedDescription, privacy: .public)")
        }
        Telemetry.shared.track(.promiseCheckedIn)
        DataMaintenance.syncWidget(context: modelContext)

        if promise.fulfillmentRate >= 1.0, promise.status == .active {
            // 全部达标后自动关闭，并取消提醒
            promise.close()
            NotificationService.shared.cancelPromiseReminder(promise)
            Telemetry.shared.track(.promiseClosed)
        }
    }
}

// MARK: - 首页区块锚点
//
// 仅用于界面核验时精确定位区块（见 UITestSupport.initialAnchor）。
// 平时它们只是 `.id(...)`，不产生任何行为。

enum HomeAnchor: String {
    case quickTools
    case promises
    case analysis
}

// MARK: - 首页空状态

struct HomeEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(.largeTitle, design: .rounded))
                .foregroundStyle(ThemeManager.Colors.primary)

            Text("先添加一个重要的人")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text("添加后就能开一次评理、追踪承诺，并记录对话。")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: onAdd) {
                Label("添加人物", systemImage: "plus")
                    .font(ThemeManager.Typography.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ThemeManager.Spacing.md)
                    .background(ThemeManager.Colors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            }
            .accessibilityHint("打开添加人物页面")
        }
        .frame(maxWidth: .infinity)
        .surfaceCard(padding: ThemeManager.Spacing.lg)
    }
}

// MARK: - 评理入口卡片
//
// 替换原 `HealthScoreCard`。
//
// 为什么删掉健康度：`score = 70 + intimacy * 3` 是把用户自己拖的滑块线性映射成
// 一个看起来像测量值的两位数，下限写死 70 使 `Band.critical` 成为死代码。
// 它不度量任何东西，却让用户以为有人在评估他的关系。
// 首页最显眼的位置应该放产品真正能交付的东西：一次把话说清的机会。

struct DisputeEntryCard: View {
    let profileCount: Int
    let activeCaseCount: Int

    var body: some View {
        NavigationLink {
            DisputeListView()
        } label: {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {

                // 大字号下的真实缺陷（XXXL 截图实证）：
                // 原来这里是固定 `HStack`，左侧 48pt 图标吃掉宽度，
                // 右侧标题在 accessibility-XXXL 下每行只剩 3 个字，
                // 整张卡长到占满一屏，把「快速工具」整个挤出可视区域。
                //
                // 用 `ViewThatFits` 而不是 `minimumScaleFactor`：
                // 后者只是把"放不下"伪装成字号问题，字最终会缩到看不见。
                // 这里让布局本身在横排放不下时退化为竖排，文字永远是原字号。
                ViewThatFits(in: .horizontal) {
                    header(horizontal: true)
                    header(horizontal: false)
                }

                if activeCaseCount > 0 {
                    HStack(spacing: ThemeManager.Spacing.sm) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(ThemeManager.Typography.caption)
                        Text("有 \(activeCaseCount) 件还没说完")
                            .font(ThemeManager.Typography.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(ThemeManager.Colors.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ThemeManager.Colors.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
                }

                HStack {
                    Text("开始")
                        .font(ThemeManager.Typography.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(ThemeManager.Typography.caption)
                }
                .foregroundStyle(ThemeManager.Colors.primary)
            }
            .padding(ThemeManager.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开评理")
    }

    @ViewBuilder
    private func header(horizontal: Bool) -> some View {
        let icon = Image(systemName: "bubble.left.and.text.bubble.right.fill")
            .font(.system(.title2, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(ThemeManager.Colors.primary)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            .accessibilityHidden(true)

        let titles = VStack(alignment: .leading, spacing: 4) {
            Text("把一件事说清")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("两个各写一份，看你们到底卡在哪")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if horizontal {
            HStack(alignment: .top, spacing: ThemeManager.Spacing.md) {
                icon
                titles
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                icon
                titles
            }
        }
    }
}

// MARK: - 快速工具入口（首页）
//
// 界面审查实测：原实现 `HStack` 固定四列 + `.lineLimit(1)` + `.minimumScaleFactor(0.8)`，
// 在 accessibility-XXXL 下四个工具被压成四个纯色方块，图标和文字全部不可读。
// `minimumScaleFactor` 是这套组合里的**反模式**——它把"放不下"这件事
// 从布局问题伪装成字重问题，实际是让文字无限缩小直到消失。
//
// 改为 `LazyVGrid` 自适应列：字号放大时列数自动从 4 → 3 → 2 → 1，
// 每个格子内容纵向排列、允许折行。

struct QuickToolsSection: View {
    /// 工具清单。
    ///
    /// 关系体检已删除：它的名字和行为都在做"评估关系"，
    /// 而整个产品是从「关系健康度 85 分」这类伪量化里走出来的。
    ///
    /// 剩下的三个里，只有「吵架复盘」是帮你想清楚；
    /// 「开口准备」「道歉准备」帮的是"准备怎么说"，不产出可以照念的成品 ——
    /// 理由见 `QuickToolKind.requiresOwnWords`。
    private let tools: [(id: String, title: String, icon: String, color: Color, detail: String)] = [
        ("conflict", "吵架复盘", "bubble.left.and.bubble.right.fill",
         ThemeManager.Colors.accent1, "一个人先理清刚才发生了什么"),
        ("phrase", "开口准备", "bandage.fill",
         ThemeManager.Colors.primary, "想清楚这次要怎么开这个口"),
        ("apology", "道歉准备", "envelope.fill",
         ThemeManager.Colors.secondary, "弄清楚这次到底在道什么")
    ]

    // 最小 132pt：既能容下"吵架复盘"四个字，又能在 375pt 宽屏上排两列。
    // 字号放大时 min 值不变、需求宽度变大 → 自动降为单列。
    private let columns = [GridItem(.adaptive(minimum: 132), spacing: ThemeManager.Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            NavigationLink {
                QuickToolsView()
            } label: {
                HStack {
                    Text("快速工具")
                        .font(ThemeManager.Typography.title3)
                        .foregroundStyle(ThemeManager.Colors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint("查看全部工具")

            // 边界说明。
            //
            // 首页同时有「评理」和「吵架复盘」两个入口，而它们的规则相反：
            //   · 评理    —— 两个人各写一份、互不可见、**不判对错**
            //   · 吵架复盘 —— 一个人写、AI 给建议，本来就是单向视角
            //
            // 不说明的话，用户吵完架不知道该点哪个：点了"复盘"会得到一个
            // 单人视角的分析，而产品真正的主张（双方各写、不做判决）完全没被用到。
            // 一句话把差别说清：一个人 / 两个人。
            // 措辞刻意不写"上面的评理"——中间还隔着别的区块，
            // 指方位的说法在长屏和滚动后都会失效。
            Text("一个人先理清思路，用这里；两个人都想被听清，用「评理」。")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // 从「宫格」改成单列列表。
            //
            // 三个格子排两列必然有一个落单，右下角空一块 —— 视觉上是残缺的。
            // 更重要的是：宫格里放不下说明文字，而这三个工具的区别恰恰在
            // 「帮你理清 / 帮你准备怎么说」，没有那行字，用户分不出该点哪个。
            VStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(tools, id: \.id) { tool in
                    // 首页四宫格直达该工具的详情页。
                    //
                    // 原来是 `QuickToolsView(initialToolID: tool.id)`，指望列表页
                    // 根据 initialToolID 自动 push 到详情 —— 但那个 push 依赖一个
                    // 从未绑定到 NavigationStack 的 path，实际无效。
                    // 结果：点任何格子都停在"选一个当下最需要的"列表页，还要再点一次。
                    //
                    // 直达目标视图是最直接的做法，也不依赖任何路径状态。
                    NavigationLink {
                        QuickToolDestination(kind: QuickToolKind(rawValue: tool.id) ?? .conflict)
                    } label: {
                        toolTile(tool)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(tool.title)
                }
            }
        }
    }

    private func toolTile(
        _ tool: (id: String, title: String, icon: String, color: Color, detail: String)
    ) -> some View {
        HStack(spacing: ThemeManager.Spacing.sm) {
            // 图标不再固定占 28pt 宽。
            //
            // 原来 `frame(width: 28)` 是为了让三个图标左边缘对齐，但代价是
            // 窄屏上白白吃掉 28pt 宽度 —— 而这一格的正文只有一行标题加一行说明。
            // 改成一个紧凑的方形底衬，视觉上更像"工具的标记"，也把宽度还给文字。
            Image(systemName: tool.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tool.color)
                .frame(width: 26, height: 26)
                .background(tool.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            // 标题与说明压到同一视觉块里，行距 1pt。
            //
            // 原来是 spacing 2 + 两行都用 `.fixedSize(vertical)`，
            // 在大字号下两块各占一行、各自撑高，格子被撑成方块。
            // 现在说明行允许被压缩，格子高度跟着内容走。
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title)
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tool.detail)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        // minHeight 从 64 降到 52，上下 padding 从 16 收到 12。
        //
        // 64+32=96pt 的总高，而内容实际只有 26pt 图标和两行小字 ——
        // 大面积留白让三行工具看起来像三张需要认真对待的大卡片，
        // 而它们其实只是三个快捷入口。压紧后一屏能看全，也更贴合文字量。
        //
        // 保留 minHeight 而不是完全去掉：一行标题+一行说明在标准字号下
        // 约 40pt，给到 52 才有可点击的余量（44pt 是 iOS 的最小触控高度）。
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, ThemeManager.Spacing.md)
        .padding(.vertical, ThemeManager.Spacing.sm + 4)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
    }
}

// MARK: - 待办承诺

struct PendingPromisesSection: View {
    let promises: [Promise]
    let onCheckIn: (Promise, FulfillmentStatus) -> Void
    /// 撤销今天的打卡（再点一次已选中状态时触发）。
    let onUndoCheckIn: (Promise) -> Void
    /// 补打昨天。
    let onBackfillCheckIn: (Promise, Date, FulfillmentStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("待办承诺")
                .font(ThemeManager.Typography.title3)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            if promises.isEmpty {
                // 修复 C8：空状态带 CTA，而不是只有一句"继续保持"
                HStack(spacing: ThemeManager.Spacing.md) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.Colors.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(promises.isEmpty ? "还没有进行中的承诺" : "全部完成")
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                        Text("在「承诺」里写下第一条")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(ThemeManager.Spacing.md)
                .surfaceCard(cornerRadius: ThemeManager.Radius.md)
            } else {
                VStack(spacing: ThemeManager.Spacing.sm) {
                    ForEach(promises.prefix(3)) { promise in
                        PromiseQuickRow(
                            promise: promise,
                            onCheck: { status in onCheckIn(promise, status) },
                            onUncheck: onUndoCheckIn,
                            onBackfill: onBackfillCheckIn
                        )
                    }
                }
            }
        }
    }
}

/// 首页的承诺快速打卡行：把"打卡"从详情页挪到一眼可见的位置。
struct PromiseQuickRow: View {
    let promise: Promise
    let onCheck: (FulfillmentStatus) -> Void
    /// 撤销今天的打卡。再点一次已选中的状态时触发。
    let onUncheck: (Promise) -> Void
    /// 补打昨天的记录。`(日期, 状态)` —— 日期固定是昨天。
    let onBackfill: (Promise, Date, FulfillmentStatus) -> Void

    /// 触感反馈的触发器。
    ///
    /// 用「计数器 + 记下这一次的反馈类型」而不是直接把 `checkedToday` 当 trigger：
    /// `checkedToday` 是计算属性，从"做到"改成"没做到"时值变了、但类型不同，
    /// 需要不同强度的反馈；而撤销时它变回 nil，也不该给"成功"的反馈。
    @State private var feedbackTick = 0
    @State private var pendingFeedback: SensoryFeedback = .success

    private var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    private var yesterdayChecked: Bool {
        promise.existingRecord(on: yesterday) != nil
    }

    private var checkedToday: FulfillmentStatus? {
        guard let raw = promise.existingRecord(on: Date())?.status else { return nil }
        return FulfillmentStatus(rawValue: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            // 大字号下 `lineLimit(2)` 会把承诺截成半个句子（"这周陪 TA 散步…"），
            // 而承诺的完整措辞正是这一行唯一的有效信息 —— 截断等于让它失去意义。
            // 改为不限制行数，让文字自然折行。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ThemeManager.Spacing.sm) {
                    contentText
                    Spacer(minLength: 0)
                    streakBadge
                }
                VStack(alignment: .leading, spacing: 4) {
                    contentText
                    streakBadge
                }
            }

            // 两个打卡按钮在大字号下会横向挤成两行文字叠在一起，
            // 放不进一行时改为竖排。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ThemeManager.Spacing.sm) {
                    checkButton(title: "今天做到了", status: .fulfilled,
                                systemImage: "checkmark.circle.fill",
                                tint: ThemeManager.Colors.secondary,
                                fill: ThemeManager.Colors.onFillSecondary)
                    checkButton(title: "没做到", status: .missed,
                                systemImage: "xmark.circle",
                                tint: ThemeManager.Colors.textSecondary,
                                fill: ThemeManager.Colors.textSecondary)
                }
                VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                    checkButton(title: "今天做到了", status: .fulfilled,
                                systemImage: "checkmark.circle.fill",
                                tint: ThemeManager.Colors.secondary,
                                fill: ThemeManager.Colors.onFillSecondary)
                    checkButton(title: "没做到", status: .missed,
                                systemImage: "xmark.circle",
                                tint: ThemeManager.Colors.textSecondary,
                                fill: ThemeManager.Colors.textSecondary)
                }
            }

            // 补打昨天。
            //
            // ## 为什么需要它
            //
            // 打卡入口只认"今天"，而人晚上 23:59 才想起来昨天忘了打是常态。
            // 连续天数对断一天极其敏感 —— 昨天漏打，今天一打也连不上，
            // 用户会觉得"反正断了"，然后放弃这个习惯。
            //
            // ## 为什么只开放"昨天"一天
            //
            // 开放任意日期等于允许补造历史记录，连续天数就失去可信度。
            // 昨天是唯一既"刚刚发生"、又还值得补的窗口。
            if !yesterdayChecked {
                Menu {
                    Button("昨天做到了") {
                        onBackfill(promise, yesterday, .fulfilled)
                    }
                    Button("昨天没做到") {
                        onBackfill(promise, yesterday, .missed)
                    }
                } label: {
                    Label("补上昨天", systemImage: "calendar.badge.plus")
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        // 补打是低频操作，但不能因此把点击区做小
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("补上昨天的记录")
                .accessibilityHint("昨天没有打卡记录，可以补上")
            }
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .sensoryFeedback(pendingFeedback, trigger: feedbackTick)
    }

    private var contentText: some View {
        Text(promise.content)
            .font(ThemeManager.Typography.subheadline)
            .foregroundStyle(ThemeManager.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var streakBadge: some View {
        if promise.streakDays > 0 {
            Text("连续 \(promise.streakDays) 天")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.accent)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func checkButton(
        title: String,
        status: FulfillmentStatus,
        systemImage: String,
        tint: Color,
        fill: Color
    ) -> some View {
        let isSelected = checkedToday == status
        Button {
            // 再点一次已选中的状态 = 撤销。
            //
            // 打卡是一点即生效的（没有确认框，否则每天一次的动作会变得很重），
            // 所以误触必然会发生。而连续天数是这个产品最核心的激励，
            // 误点一次「没做到」就把记录断掉、且没有任何补救手段，是不可接受的。
            //
            // 用「可回退」而不是「加确认框」：误触低频，确认框却每次都挡人。
            // 轻触即改的控件必须有触感，否则用户不确定自己点到了没有 ——
            // 下一帧卡片才重绘，那一瞬间的空白会让人想再点一次。
            if isSelected {
                pendingFeedback = .impact(weight: .light)
                onUncheck(promise)
            } else {
                pendingFeedback = status == .fulfilled ? .success : .warning
                onCheck(status)
            }
            feedbackTick += 1
        } label: {
            Label(isSelected ? "\(title)· 点一下撤销" : title, systemImage: systemImage)
                .font(ThemeManager.Typography.caption)
                // 选中态是**实心填充 + 白字**，必须用深色变体：
                // 原品牌绿 #10B981 压白字只有 2.54:1，远低于 AA 的 4.5:1；
                // 换成 #047857 后是 5.38:1。这是首页最高频的动作，不能糊。
                .foregroundStyle(isSelected ? .white : tint)
                .padding(.horizontal, 12)
                // 界面审查实测：原 `padding(.vertical, 6)` + `.caption` 使点击区只有 24–26pt，
                // 远低于 44pt 最低要求。这里把最小高度钉死在 44。
                .frame(minHeight: 44)
                .background(isSelected ? fill : tint.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "\(title)，已记录，点击撤销" : title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - 对话分析（录音 + 历史记录，合并为一个区块）
//
// ## 为什么把三个区块合成一个
//
// 原来首页有「录一段」「最近记录」「分析报告」三块，加上评理入口、快速工具、
// 待办承诺，一共 6 个区块。而这个产品的定位是**评理**，
// 6 块里只有 1 块属于主线，其余 5 块都是录音分析时代留下的历史功能。
//
// 后果不是"页面长"，是**新用户看不出主路径**：
// 打开首页，最显眼的不是评理，而是一堆并列的入口卡。
//
// 合并后：录音、历史、分析本来就是同一件事的三个动作（录 → 看 → 全部），
// 收进一个区块，首页从 6 块降到 4 块，主线自然浮出来。

struct DialogueAnalysisSection: View {
    let sessions: [RecordingSession]

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("对话分析")
                    .font(ThemeManager.Typography.title3)
                    .foregroundStyle(ThemeManager.Colors.textPrimary)

                Spacer(minLength: ThemeManager.Spacing.sm)

                // 有记录时才给「全部」，否则点进去是空列表
                if !sessions.isEmpty {
                    NavigationLink {
                        AnalysisView()
                    } label: {
                        Text("全部 \(sessions.count) 条")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.primary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看全部 \(sessions.count) 条分析记录")
                }
            }

            NavigationLink {
                RecordingView()
            } label: {
                HStack(spacing: ThemeManager.Spacing.md) {
                    Image(systemName: "mic.fill")
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(ThemeManager.Colors.accent2)
                        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("录一段")
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundStyle(ThemeManager.Colors.textPrimary)
                        Text(sessions.isEmpty ? "边录边转成文字" : "已经录过 \(sessions.count) 次")
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
            }
            .buttonStyle(.plain)

            if sessions.isEmpty {
                Text("还没有记录。录一段对话，或先从上面开始一次评理。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: ThemeManager.Spacing.sm) {
                    ForEach(sessions.prefix(3)) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            ActivityRow(
                                icon: session.kind == .conflict
                                    ? "exclamationmark.bubble.fill"
                                    : "waveform",
                                tint: session.kind == .conflict
                                    ? ThemeManager.Colors.accent
                                    : ThemeManager.Colors.primary,
                                title: session.kind.displayName,
                                subtitle: session.analysisResult?.summary?.isEmpty == false
                                    ? (session.analysisResult?.summary ?? "")
                                    : (session.transcription.map { String($0.prefix(28)) } ?? "无转写"),
                                time: AppFormatters.relativeText(for: session.createdAt)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let time: String

    var body: some View {
        // XXXL 下的实测缺陷（截图证实）：
        // 原来是一条固定 `HStack`：38pt 图标 + 标题 + 单行摘要 + 右侧时间。
        // 大字号时标题被挤成逐字换行（「冲突 / 复盘」），
        // 右侧时间被压成两行（「1 小 / 时前」），摘要在单行里被截成「沟通还…」。
        // 后者最严重：它是这一行唯一的实质内容，截断等于没有任何信息。
        //
        // 用 ViewThatFits 让横排放不下时退化为两段式：
        // 上一行 图标+标题+时间，下一行 完整摘要（可多行）。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: ThemeManager.Spacing.md) {
                iconBadge
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    subtitleText
                }
                Spacer(minLength: 0)
                timeText
            }
            VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
                HStack(alignment: .top, spacing: ThemeManager.Spacing.md) {
                    iconBadge
                    titleText
                    Spacer(minLength: 0)
                    timeText
                }
                subtitleText
            }
        }
        .padding(ThemeManager.Spacing.md)
        .surfaceCard(cornerRadius: ThemeManager.Radius.md)
        .accessibilityElement(children: .combine)
    }

    private var iconBadge: some View {
        Image(systemName: icon)
            .font(.body)
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.sm, style: .continuous))
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(ThemeManager.Typography.subheadline)
            .foregroundStyle(ThemeManager.Colors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var subtitleText: some View {
        // 不设 lineLimit：摘要是这一行唯一的内容，宁可多两行也不截断。
        Text(subtitle)
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private var timeText: some View {
        Text(time)
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            .fixedSize()
    }
}

// MARK: - 录音入口
//
// 改版后「记录」不再是一级 tab。录音仍然可用，但它是评理之外的补充手段：
// 评理处理"这次没说清的事"，录音处理"发生了什么"的留存。
// 把它放在首页卡片而非 tab，是为了让首页的第一落点始终是评理。



// MARK: - 分析报告入口



// MARK: - 按压反馈样式
//
// 修复报告 A：原 `ScaleButtonStyle` 是空实现（`makeBody` 直接返回 label），
// 即"定义了样式但没有任何反馈"；同时 3 处页面各自复制 `DragGesture(minimumDistance: 0)` 做缩放。
// 现在统一为一个真实生效的 ButtonStyle。

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
