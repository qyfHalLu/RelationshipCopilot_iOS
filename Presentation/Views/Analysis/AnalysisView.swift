import SwiftUI
import SwiftData

struct AnalysisView: View {
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // 分析概览
                    AnalysisOverviewCard()
                    
                    // 历史记录列表
                    HistorySection(sessions: sessions)
                }
                .padding(.horizontal, ThemeManager.Spacing.md)
                .padding(.vertical, ThemeManager.Spacing.lg)
            }
            .background(ThemeManager.Colors.background)
            .navigationTitle("分析报告")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - 分析概览卡片
struct AnalysisOverviewCard: View {
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            Text("本月分析概览")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            HStack(spacing: ThemeManager.Spacing.lg) {
                OverviewStat(
                    icon: "doc.text.fill",
                    value: "12",
                    label: "分析次数",
                    color: .blue
                )
                
                OverviewStat(
                    icon: "arrow.up.circle.fill",
                    value: "+15%",
                    label: "关系改善",
                    color: .green
                )
                
                OverviewStat(
                    icon: "lightbulb.fill",
                    value: "48",
                    label: "获得建议",
                    color: .orange
                )
            }
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.lg)
        .shadow(ThemeManager.Shadows.md)
        .opacity(isAnimating ? 1 : 0)
        .offset(y: isAnimating ? 0 : 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - 概览统计
struct OverviewStat: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            Text(label)
                .font(ThemeManager.Typography.caption)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 历史记录
struct HistorySection: View {
    let sessions: [RecordingSession]
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            Text("历史记录")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            if sessions.isEmpty {
                EmptyHistoryView()
            } else {
                LazyVStack(spacing: ThemeManager.Spacing.md) {
                    ForEach(sessions) { session in
                        HistoryItem(session: session)
                    }
                }
            }
        }
    }
}

// MARK: - 空历史视图
struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(ThemeManager.Colors.textSecondary.opacity(0.5))
            
            Text("暂无分析记录")
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            Text("开始录音对话，获取AI分析报告")
                .font(ThemeManager.Typography.subheadline)
                .foregroundColor(ThemeManager.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(ThemeManager.Spacing.xl)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.lg)
        .shadow(ThemeManager.Shadows.sm)
    }
}

// MARK: - 历史项
struct HistoryItem: View {
    let session: RecordingSession
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            // 查看详情
        }) {
            HStack(spacing: ThemeManager.Spacing.md) {
                // 类型图标
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.2))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: iconName)
                        .font(.title3)
                        .foregroundColor(iconColor)
                }
                
                // 信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundColor(ThemeManager.Colors.textPrimary)
                    
                    Text(formattedDate)
                        .font(ThemeManager.Typography.caption)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                }
                
                Spacer()
                
                // 状态
                Text(statusText)
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(ThemeManager.Radius.full)
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .cornerRadius(ThemeManager.Radius.lg)
            .shadow(ThemeManager.Shadows.sm)
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .pressEvents {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = true
            }
        } onRelease: {
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = false
            }
        }
    }
    
    private var iconName: String {
        switch session.sessionType {
        case "conflict": return "exclamationmark.triangle.fill"
        case "conversation": return "bubble.left.fill"
        default: return "mic.fill"
        }
    }
    
    private var iconColor: Color {
        switch session.sessionType {
        case "conflict": return .orange
        case "conversation": return .blue
        default: return .purple
        }
    }
    
    private var title: String {
        switch session.sessionType {
        case "conflict": return "冲突分析"
        case "conversation": return "对话分析"
        default: return "录音分析"
        }
    }
    
    private var statusText: String {
        switch session.status {
        case "analyzed": return "已完成"
        case "completed": return "待分析"
        default: return "进行中"
        }
    }
    
    private var statusColor: