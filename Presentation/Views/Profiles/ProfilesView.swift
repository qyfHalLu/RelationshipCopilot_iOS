//
//  ProfilesView.swift
//  RelationshipCopilot
//
//  人物关系管理视图
//

import SwiftUI
import SwiftData

struct ProfilesView: View {
    @Query(sort: \Profile.updatedAt, order: .reverse) private var profiles: [Profile]
    @State private var showAddProfile = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.lg) {
                    // 关系统统
                    RelationshipStatsCard(profileCount: profiles.count)
                    
                    // 人物列表
                    if profiles.isEmpty {
                        EmptyStateView(
                            icon: "person.2.slash",
                            title: "还没有人物",
                            subtitle: "添加第一个重要的人吧"
                        )
                    } else {
                        LazyVStack(spacing: ThemeManager.Spacing.md) {
                            ForEach(profiles) { profile in
                                NavigationLink(value: profile) {
                                    ProfileCard(profile: profile)
                                }
                            }
                        }
                        .navigationDestination(for: Profile.self) { profile in
                            ProfileDetailView(profile: profile)
                        }
                    }
                    
                    // 添加按钮
                    AddProfileButton {
                        showAddProfile = true
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
                    Button(action: {
                        showAddProfile = true
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(ThemeManager.Colors.primary)
                    }
                }
            }
            .sheet(isPresented: $showAddProfile) {
                AddProfileView()
            }
        }
    }
}

// MARK: - 关系统计卡片
struct RelationshipStatsCard: View {
    let profileCount: Int
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: ThemeManager.Spacing.lg) {
            StatItem(
                icon: "person.2.fill",
                value: "\(profileCount)",
                label: "关系数",
                color: ThemeManager.Colors.primary
            )
            
            Divider()
                .frame(height: 40)
            
            StatItem(
                icon: "heart.fill",
                value: "82",
                label: "平均健康度",
                color: ThemeManager.Colors.secondary
            )
            
            Divider()
                .frame(height: 40)
            
            StatItem(
                icon: "checkmark.circle.fill",
                value: "75%",
                label: "履约率",
                color: ThemeManager.Colors.accent
            )
        }
        .padding(ThemeManager.Spacing.lg)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        .opacity(isAnimating ? 1 : 0)
        .offset(y: isAnimating ? 0 : 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - 统计项
struct StatItem: View {
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

// MARK: - 人物卡片
struct ProfileCard: View {
    let profile: Profile
    @State private var isPressed = false
    
    var body: some View {
        NavigationLink(destination: ProfileDetailView(profile: profile)) {
            HStack(spacing: ThemeManager.Spacing.md) {
                // 头像
                ZStack {
                    Circle()
                        .fill(avatarColor.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    Text(initials)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(avatarColor)
                }
                
                // 信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(ThemeManager.Typography.headline)
                        .foregroundColor(ThemeManager.Colors.textPrimary)
                    
                    Text(relationshipTypeText)
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                    
                    // 亲密度指示
                    HStack(spacing: 4) {
                        ForEach(0..<5) { index in
                            Image(systemName: index < profile.intimacyScore / 2 ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    }
                }
                
                Spacer()
                
                // 健康度
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(healthScore)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(healthColor)
                    
                    Text("健康度")
                        .font(ThemeManager.Typography.caption)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
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
    
    private var initials: String {
        String(profile.name.prefix(1))
    }
    
    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green]
        return colors[abs(profile.name.hashValue) % colors.count]
    }
    
    private var relationshipTypeText: String {
        switch profile.relationshipType {
        case "partner": return "伴侣"
        case "family": return "家人"
        case "friend": return "朋友"
        case "colleague": return "同事"
        default: return "其他"
        }
    }
    
    private var healthScore: Int {
        return 70 + (profile.intimacyScore * 3)
    }
    
    private var healthColor: Color {
        switch healthScore {
        case 0...40: return ThemeManager.Colors.danger
        case 41...60: return ThemeManager.Colors.accent
        case 61...80: return ThemeManager.Colors.secondary
        default: return ThemeManager.Colors.primary
        }
    }
}

// MARK: - 添加人物按钮
struct AddProfileButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("添加人物")
            }
            .font(ThemeManager.Typography.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(ThemeManager.Spacing.md)
            .background(ThemeManager.Colors.primary)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.lg))
        }
    }
}

// MARK: - 空状态视图
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: ThemeManager.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(ThemeManager.Colors.border)
            
            Text(title)
                .font(ThemeManager.Typography.title3)
                .foregroundColor(ThemeManager.Colors.textPrimary)
            
            Text(subtitle)
                .font(ThemeManager.Typography.callout)
                .foregroundColor(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
    }
}

#Preview {
    ProfilesView()
        .modelContainer(for: [Profile.self, Promise.self, RecordingSession.self], inMemory: true)
}