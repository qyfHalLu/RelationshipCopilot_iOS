import SwiftUI
import SwiftData
import StoreKit

// MARK: - 设置
//
// 修复报告 C3 / C4 / C2 / F4：
//  - C3：`SettingsView` 原先全仓库零引用（完全不可达），用户无法登出、无法看隐私政策。
//        现在从首页右上角齿轮与「我的」页均可进入。
//  - C4：「深色模式」原为 `Toggle(isOn: .constant(true)).disabled(true)`，
//        显示"已开启"但实际永远不开。现在改为三态外观（跟随系统/浅色/深色）并真正生效。
//  - C2：用户信息原为硬编码「用户昵称 / 138****8888」，现在取真实登录态。
//  - F4：「给我们评分」原是 `Text("评分")` 占位，现在调用系统的 `requestReview`。

struct SettingsView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview

    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("dailyReminderEnabled") private var dailyReminderEnabled = true
    @AppStorage("dailyReminderHour") private var dailyReminderHour = 9
    @AppStorage("promiseReminderEnabled") private var promiseReminderEnabled = true

    @State private var notificationState: NotificationService.AuthorizationState = .notDetermined
    @State private var showLogoutAlert = false
    #if DEBUG
    /// 调试用：手工录入直连密钥（写入 Keychain，不进源码、不进 IPA）。
    @State private var directKeyDraft = ""
    @State private var keySaveStatus: String?
    #endif
    /// 内测用：代理共享令牌。不受 `#if DEBUG` 约束 —— 内测发的是 Release 包。
    @State private var proxyTokenDraft = ""
    @State private var proxyTokenStatus: String?

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        List {
            appearanceSection
            notificationSection
            aiSection
            #if DEBUG
            debugKeySection
            #endif
            betaProxyTokenSection
            aboutSection
            accountSection
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshNotificationState() }
        .alert("确认退出登录？", isPresented: $showLogoutAlert) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { authService.logout() }
        } message: {
            Text("退出后本机数据仍会保留，下次登录可继续使用。")
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section {
            Picker("外观", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("外观")
        } footer: {
            Text("选择「跟随系统」时会随 iOS 的深色模式自动切换。")
        }
    }

    // MARK: 通知

    private var notificationSection: some View {
        Section {
            if notificationState == .denied {
                HStack(spacing: ThemeManager.Spacing.sm) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(ThemeManager.Colors.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("通知权限已关闭")
                            .font(ThemeManager.Typography.subheadline)
                        Text("需要到系统设置里开启")
                            .font(ThemeManager.Typography.caption)
                            .foregroundStyle(ThemeManager.Colors.textSecondary)
                    }
                    Spacer()
                    Button("去设置") { openSystemSettings() }
                        .font(ThemeManager.Typography.subheadline)
                }
            } else {
                Toggle("每日提醒", isOn: $dailyReminderEnabled)
                    .onChange(of: dailyReminderEnabled) { _, enabled in
                        applyDailyReminder(enabled: enabled)
                    }

                if dailyReminderEnabled {
                    Picker("提醒时间", selection: $dailyReminderHour) {
                        ForEach(7..<23, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .onChange(of: dailyReminderHour) { _, _ in
                        if dailyReminderEnabled { applyDailyReminder(enabled: true) }
                    }
                }

                Toggle("承诺到期提醒", isOn: $promiseReminderEnabled)
            }
        } header: {
            Text("通知")
        } footer: {
            Text("承诺提醒会在截止前 1 小时发出；每日提醒只在你主动开启后才会申请系统权限。")
        }
    }

    // MARK: AI

    private var aiSection: some View {
        Section {
            HStack {
                Text("AI 服务")
                Spacer()
                Text(AIService.shared.isConfigured ? "已接入" : "未配置")
                    .foregroundStyle(AIService.shared.isConfigured
                                     ? ThemeManager.Colors.secondary
                                     : ThemeManager.Colors.textSecondary)
            }
            HStack {
                Text("今日剩余次数")
                Spacer()
                Text("\(AIService.shared.remainingQuota) / \(AIService.shared.dailyLimit)")
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
            // 速率诊断。评理有硬性速率约束（RPM / TPM），撞到不是"变慢"而是直接 429。
            // 把这个数字摆出来，用户就知道"点了没反应"到底是在等还是坏了。
            if AIService.shared.isConfigured {
                HStack {
                    Text("当前可发")
                    Spacer()
                    Text(AIService.shared.rateLimitDiagnostics)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if !AIService.shared.isConfigured {
                Text("当前构建没有配置 AI 服务地址。分析功能会明确提示不可用，不会返回编造的结果。")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
        } header: {
            Text("AI 服务")
        } footer: {
            Text("内容只保存在这台手机上。生成评理结果时会发给模型服务一次，不会留存到我们的服务器。")
        }
    }

    // MARK: 调试密钥（仅 Debug）

    #if DEBUG
    /// 直连密钥的录入入口。
    ///
    /// ## 为什么要有这个界面，而不是把密钥写进 Info.plist
    ///
    /// 这个仓库因为「把 API 密钥硬编码进 `AIService.swift:277` 并提交到公开仓库」
    /// 已经出过一次安全事件，暴露约 7.5 个月。
    /// 把密钥写进 Info.plist 是同一个错误换了个文件 —— Info.plist 会打进 IPA，
    /// 任何能解包 IPA 的人都能拿到。
    ///
    /// 所以：密钥只存在 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`），
    /// 由使用者本人在本机粘贴，**不经过源码、不经过 git、不经过构建产物**。
    /// 这整个区块被 `#if DEBUG` 包住，Release 构建里不存在。
    private var debugKeySection: some View {
        Section {
            SecureField("粘贴 API Key", text: $directKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))

            Button {
                saveDirectKey()
            } label: {
                Label("保存到钥匙串", systemImage: "key.fill")
            }
            .disabled(directKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let keySaveStatus {
                Text(keySaveStatus)
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
        } header: {
            Text("调试：直连密钥")
        } footer: {
            Text("仅 Debug 构建可见。密钥写入钥匙串，不进入源码与构建产物。保存后需重启 App 才会重新解析接入方式。")
        }
    }

    private func saveDirectKey() {
        let trimmed = directKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try SecureStorageService.shared.save(
                key: EndpointConfiguration.directKeychainAccount,
                value: trimmed
            )
            // 立刻从内存里抹掉，避免明文停留在视图状态里
            directKeyDraft = ""
            keySaveStatus = "已保存。重启 App 后生效。"
        } catch {
            keySaveStatus = "保存失败：\(error.localizedDescription)"
        }
    }
    #endif

    // MARK: 内测代理令牌

    /// 内测期录入代理共享令牌。
    ///
    /// ## 为什么它必须能在 Release 里出现
    ///
    /// 上面那个 `debugKeySection` 被 `#if DEBUG` 包着，而内测发的是 Release 包。
    /// 代理部署好之后，App 不带 `x-app-token` 就只会拿到 401 ——
    /// 表现是"AI 一直失败"，而真实原因是少了一个头。
    ///
    /// 所以这里单独开一个入口，只在 `RCAllowBetaSkipAuth` 为 true 时可见。
    /// 上架前把那个开关关掉，这个区块随之消失。
    ///
    /// 令牌同样只进 Keychain，不进 Info.plist ——
    /// Info.plist 会打进 IPA，任何能解包的人都能拿到，那是本项目已经踩过的坑。
    @ViewBuilder
    private var betaProxyTokenSection: some View {
        if EndpointConfiguration.allowsBetaSkipAuth() {
            Section {
                SecureField("粘贴内测访问令牌", text: $proxyTokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))

                Button {
                    saveProxyToken()
                } label: {
                    Label("保存到钥匙串", systemImage: "key.fill")
                }
                .disabled(proxyTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let proxyTokenStatus {
                    Text(proxyTokenStatus)
                        .font(ThemeManager.Typography.caption)
                        .foregroundStyle(ThemeManager.Colors.textSecondary)
                }
            } header: {
                Text("内测：访问令牌")
            } footer: {
                Text("内测期间由开发者提供。令牌写入钥匙串，保存后需重启 App 生效。")
            }
        }
    }

    private func saveProxyToken() {
        let trimmed = proxyTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try SecureStorageService.shared.save(
                key: EndpointConfiguration.proxyTokenKeychainAccount,
                value: trimmed
            )
            proxyTokenDraft = ""
            proxyTokenStatus = "已保存。重启 App 后生效。"
        } catch {
            proxyTokenStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section("关于") {
            NavigationLink {
                HelpView()
            } label: {
                Label("帮助与反馈", systemImage: "questionmark.circle")
            }

            Button {
                requestReview()
            } label: {
                Label("给我们评分", systemImage: "star")
            }

            HStack {
                Label("版本", systemImage: "info.circle")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: 账号

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutAlert = true
            } label: {
                HStack {
                    Spacer()
                    Text("退出登录")
                    Spacer()
                }
            }
        }
    }

    // MARK: 动作

    private func refreshNotificationState() async {
        notificationState = await NotificationService.shared.authorizationState()
    }

    private func applyDailyReminder(enabled: Bool) {
        Task {
            if enabled {
                let state = await NotificationService.shared.requestAuthorizationIfNeeded()
                notificationState = state
                guard state == .authorized else {
                    dailyReminderEnabled = false
                    return
                }
                NotificationService.shared.scheduleDailyReminder(hour: dailyReminderHour)
            } else {
                NotificationService.shared.cancelDailyReminder()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
