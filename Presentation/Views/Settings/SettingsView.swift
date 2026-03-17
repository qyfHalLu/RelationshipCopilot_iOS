import SwiftUI

struct SettingsView: View {
    @Environment(AuthenticationService.self) private var authService
    @State private var showLogoutAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                // 用户信息
                UserSection()
                
                // 通用设置
                GeneralSection()
                
                // 通知设置
                NotificationSection()
                
                // 隐私与安全
                PrivacySection()
                
                // 关于
                AboutSection()
                
                // 退出登录
                LogoutSection(showLogoutAlert: $showLogoutAlert)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .alert("确认退出", isPresented: $showLogoutAlert) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    authService.logout()
                }
            } message: {
                Text("确定要退出登录吗？")
            }
        }
    }
}

// MARK: - 用户区块
struct UserSection: View {
    var body: some View {
        Section {
            HStack(spacing: ThemeManager.Spacing.md) {
                // 头像
                ZStack {
                    Circle()
                        .fill(ThemeManager.Colors.primary.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    Text("用")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(ThemeManager.Colors.primary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户昵称")
                        .font(ThemeManager.Typography.headline)
                        .foregroundColor(ThemeManager.Colors.textPrimary)
                    
                    Text("138****8888")
                        .font(ThemeManager.Typography.subheadline)
                        .foregroundColor(ThemeManager.Colors.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 通用设置
struct GeneralSection: View {
    @AppStorage("darkMode") private var darkMode = false
    @AppStorage("hapticFeedback") private var hapticFeedback = true
    
    var body: some View {
        Section("通用") {
            Toggle(isOn: $darkMode) {
                Label("深色模式", systemImage: "moon.fill")
            }
            
            Toggle(isOn: $hapticFeedback) {
                Label("触觉反馈", systemImage: "hand.tap.fill")
            }
            
            NavigationLink {
                Text("语言设置")
            } label: {
                Label("语言", systemImage: "globe")
            }
        }
    }
}

// MARK: - 通知设置
struct NotificationSection: View {
    @AppStorage("pushEnabled") private var pushEnabled = true
    @AppStorage("reminderEnabled") private var reminderEnabled = true
    
    var body: some View {
        Section("通知") {
            Toggle(isOn: $pushEnabled) {
                Label("推送通知", systemImage: "bell.fill")
            }
            
            Toggle(isOn: $reminderEnabled) {
                Label("承诺提醒", systemImage: "alarm.fill")
            }
        }
    }
}

// MARK: - 隐私与安全
struct PrivacySection: View {
    var body: some View {
        Section("隐私与安全") {
            NavigationLink {
                Text("隐私政策")
            } label: {
                Label("隐私政策", systemImage: "shield.fill")
            }
            
            NavigationLink {
                Text("数据管理")
            } label: {
                Label("数据管理", systemImage: "externaldrive.fill")
            }
            
            NavigationLink {
                Text("账号安全")
            } label: {
                Label("账号安全", systemImage: "lock.fill")
            }
        }
    }
}

// MARK: - 关于
struct AboutSection: View {
    var body: some View {
        Section("关于") {
            HStack {
                Label("版本", systemImage: "info.circle.fill")
                Spacer()
                Text("1.0.0")
                    .foregroundColor(ThemeManager.Colors.textSecondary)
            }
            
            NavigationLink {
                Text("帮助与反馈")
            } label: {
                Label("帮助与反馈", systemImage: "questionmark.circle.fill")
            }
            
            NavigationLink {
                Text("评分")
            } label: {
                Label("给我们评分", systemImage: "star.fill")
            }
        }
    }
}

// MARK: - 退出登录
struct LogoutSection: View {
    @Binding var showLogoutAlert: Bool
    
    var body: some View {
        Section {
            Button(action: {
                showLogoutAlert = true
            }) {
                HStack {
                    Spacer()
                    Text("退出登录")
                        .foregroundColor(.red)
                    Spacer()
                }
            }
        }
    }
}
