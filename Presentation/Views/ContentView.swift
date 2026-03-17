import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AuthenticationService.self) private var authService
    
    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainTabView()
            } else {
                AuthenticationView()
            }
        }
        .animation(.smooth(duration: 0.3), value: authService.isAuthenticated)
    }
}

// MARK: - 主标签页
struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)
            
            ProfilesView()
                .tabItem {
                    Label("关系", systemImage: "person.2.fill")
                }
                .tag(1)
            
            PromisesView()
                .tabItem {
                    Label("承诺", systemImage: "checklist")
                }
                .tag(2)
            
            RecordingView()
                .tabItem {
                    Label("记录", systemImage: "mic.fill")
                }
                .tag(3)
            
            AnalysisView()
                .tabItem {
                    Label("分析", systemImage: "chart.bar.fill")
                }
                .tag(4)
            
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gear")
                }
                .tag(5)
        }
        .tint(ThemeManager.Colors.primary)
    }
}

// MARK: - 首页视图
struct HomeView: View {
    @Query private var profiles: [Profile]
    @Query(sort: \Promise.committedAt, order: .reverse) private var promises: [Promise]
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]
    
    var averageHealthScore: Int {
        guard !profiles.isEmpty else { return 0 }
        let total = profiles.reduce(0) { $0 + $1.healthScore }
        return total / profiles.count
    }
    
    var streakDays: Int {
        // 简化计算：基于履约率
        let completedCount = promises.filter { $0.fulfillmentRate > 0.5 }.count
        return min(completedCount, 30)
    }
    
    var pendingPromises: [Promise] {
        promises.filter { $0.trackingStatus == "active" }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // 健康度卡片
                    HealthScoreCard(score: averageHealthScore, streakDays: streakDays)
                    
                    // 快速操作
                    QuickActionsGrid()
                    
                    // 最近动态
                    RecentActivitySection()
                    
                    // 待办提醒
                    TodoSection(pendingPromises: pendingPromises)
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("关系副驾")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - 健康度卡片
struct HealthScoreCard: View {
    let score: Int
    let streakDays: Int
    @State private var isAnimating = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            HStack {
                Text("关系健康度")
                    .font(ThemeManager.Typography.title3)
                    .foregroundColor(ThemeManager.Colors.textPrimary)
                
                Spacer()
                
                // 连续天数徽章
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.orange)
                    Text("\(streakDays)天")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .clipShape(Capsule())
            }
            
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(score)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(scoreColor)
                    .scaleEffect(isAnimating ? 1.0 : 0.8)
                    .opacity(isAnimating ? 1.0 : 0.0)
                
                Text("/100")
                    .font(ThemeManager.Typography.title2)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            
            // 进度条
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ThemeManager.Colors.border)
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [scoreColor, scoreColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: isAnimating ? geometry.size.width * CGFloat(score) / 100 : 0, height: 8)
                        .animation(.easeOut(duration: 1.0).delay(0.3), value: isAnimating)
                }
            }
            .frame(height: 8)
            
            Text(scoreDescription)
                .font(ThemeManager.Typography.callout)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isAnimating = true
            }
        }
    }
    
    private var scoreColor: Color {
        switch score {
        case 0...40: return ThemeManager.Colors.danger
        case 41...60: return ThemeManager.Colors.accent
        case 61...80: return ThemeManager.Colors.secondary
        default: return ThemeManager.Colors.primary
        }
    }
    
    private var scoreDescription: String {
        switch score {
        case 0...40: return "需要关注，建议立即改善"
        case 41...60: return "有提升空间，继续努力"
        case 61...80: return "关系良好，保持稳定"
        default: return "关系优秀，继续保持"
        }
    }
}

// MARK: - 快速操作网格
struct QuickActionsGrid: View {
    let actions = [
        ("吵架复盘", "bubble.left.and.bubble.right.fill", Color.purple),
        ("话术急救", "bandage.fill", Color.blue),
        ("道歉生成", "envelope.fill", Color.green),
        ("关系体检", "heart.text.fill", Color.red)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("快速工具")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: ThemeManager.Spacing.md) {
                ForEach(actions, id: \.0) { action in
                    QuickActionButton(
                        title: action.0,
                        icon: action.1,
                        color: action.2
                    )
                }
            }
        }
    }
}

// MARK: - 快速操作按钮
struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            // 操作
        }) {
            HStack(spacing: ThemeManager.Spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                
                Text(title)
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundColor(ThemeManager.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
            .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(ScaleButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isPressed = false
                    }
                }
        )
    }
}

// MARK: - 最近动态
struct RecentActivitySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("最近动态")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            VStack(spacing: ThemeManager.Spacing.sm) {
                ActivityItem(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "完成了今日承诺",
                    subtitle: "主动关心对方的工作",
                    time: "2小时前"
                )
                
                ActivityItem(
                    icon: "document.fill",
                    color: .blue,
                    title: "生成了关系分析报告",
                    subtitle: "本周关系健康度提升5%",
                    time: "昨天"
                )
            }
        }
    }
}

// MARK: - 活动项
struct ActivityItem: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let time: String
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundColor(ThemeManager.Colors.textPrimary)
                
                Text(subtitle)
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            
            Spacer()
            
            Text(time)
                .font(ThemeManager.Typography.caption)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .padding(ThemeManager.Spacing.md)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 待办提醒
struct TodoSection: View {
    let pendingPromises: [Promise]
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("待办提醒")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            if pendingPromises.isEmpty {
                // 空状态
                HStack(spacing: ThemeManager.Spacing.md) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundColor(ThemeManager.Colors.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所有承诺已完成")
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundColor(ThemeManager.Colors.textPrimary)
                        
                        Text("继续保持！")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                    }
                    
                    Spacer()
                }
                .padding(ThemeManager.Spacing.md)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
            } else {
                // 显示待办
                HStack(spacing: ThemeManager.Spacing.md) {
                    Image(systemName: "bell.fill")
                        .font(.title2)
                        .foregroundColor(ThemeManager.Colors.accent)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本周承诺自查")
                            .font(ThemeManager.Typography.subheadline)
                            .foregroundColor(ThemeManager.Colors.textPrimary)
                        
                        Text("还有\(pendingPromises.count)条承诺待完成")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                    }
                    
                    Spacer()
                    
                    Button("去查看") {
                        // 导航到承诺页面
                    }
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundColor(ThemeManager.Colors.primary)
                }
                .padding(ThemeManager.Spacing.md)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md))
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
        }
    }
}

// MARK: - 按钮样式
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}