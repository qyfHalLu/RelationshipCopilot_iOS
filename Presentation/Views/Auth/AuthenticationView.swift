import SwiftUI
import LocalAuthentication
import Combine

// MARK: - 登录页
//
// 修复报告 C7 / D / F3：
//  - C7（P1）：原验证码是 6 个独立 TextField，输入一位后 `isFocused = false` 会收起键盘，
//    用户必须逐格点击；`setDigit` 只接受 `count == 1`，粘贴/自动填充 6 位被整段忽略；
//    也没有 `.textContentType(.oneTimeCode)`，iOS 短信自动填充失效。
//    现在改为「一个隐藏输入框 + 6 个展示格」，支持粘贴与自动填充，输满自动提交。
//  - 原「跳过登录」按钮（把 "test_user" 当手机号）是测试后门，已移除；
//    仅在 DEBUG 构建保留，且明确标注为演示。
//  - 原「用户协议 / 隐私政策」是空动作 `Button(...) {}`，审核 5.1.1 直接不通过。
//    现在跳转到真实的条款页面（`LegalViews.swift`）。
//  - 生物识别按钮改为「设备支持时才显示」，并在 Info.plist 补了 NSFaceIDUsageDescription。

struct AuthenticationView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(\.colorScheme) private var scheme

    @State private var phoneNumber = ""
    @State private var code = ""
    @State private var step: Step = .phone
    @State private var resendRemaining = 0
    @State private var showLegal: LegalDocument?
    @State private var isBiometricRunning = false

    @FocusState private var codeFieldFocused: Bool
    @FocusState private var phoneFieldFocused: Bool

    private enum Step: Equatable {
        case phone
        case code
    }

    private let countdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isPhoneValid: Bool {
        Validation.isValidPhone(phoneNumber)
    }

    private var isCodeComplete: Bool {
        Validation.isValidCode(code)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ThemeManager.Spacing.xl) {
                    header

                    if step == .phone {
                        phoneSection
                    } else {
                        codeSection
                    }

                    if let error = authService.error, error.isBlocking {
                        errorBanner(error)
                    }

                    primaryButton

                    if authService.canUseBiometrics {
                        biometricButton
                    }

                    if authService.canSkipAuthForBeta {
                        betaSkipButton
                    }

                    #if DEBUG
                    demoLoginButton
                    #endif

                    Spacer(minLength: ThemeManager.Spacing.lg)

                    legalFooter
                }
                .padding(.horizontal, ThemeManager.Spacing.lg)
                .padding(.top, ThemeManager.Spacing.xl)
                .padding(.bottom, ThemeManager.Spacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ThemeManager.Colors.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $showLegal) { document in
                LegalDocumentView(document: document)
            }
            .onReceive(countdown) { _ in
                if resendRemaining > 0 { resendRemaining -= 1 }
            }
            .onChange(of: code) { _, newValue in
                let filtered = Validation.digitsOnly(newValue, maxLength: 6)
                if filtered != newValue { code = filtered }
                if filtered.count == 6 {
                    submitCode()
                }
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: ThemeManager.Spacing.md) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(ThemeManager.Colors.primary)
                .accessibilityHidden(true)

            Text("关系副驾")
                .font(ThemeManager.Typography.largeTitle)
                .foregroundStyle(ThemeManager.Colors.textPrimary)

            Text("记录对话，看清关系里的模式")
                .font(ThemeManager.Typography.body)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, ThemeManager.Spacing.lg)
    }

    // MARK: 手机号

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("手机号")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            HStack(spacing: ThemeManager.Spacing.sm) {
                Text("+86")
                    .font(ThemeManager.Typography.body)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)

                Divider().frame(height: 22)

                TextField("请输入手机号", text: $phoneNumber)
                    .font(ThemeManager.Typography.body)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .focused($phoneFieldFocused)
                    .onChange(of: phoneNumber) { _, newValue in
                        let filtered = Validation.digitsOnly(newValue, maxLength: 11)
                        if filtered != newValue { phoneNumber = filtered }
                    }
                    .accessibilityLabel("手机号")
            }
            .padding(ThemeManager.Spacing.md)
            .background(ThemeManager.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))

            if !phoneNumber.isEmpty && !isPhoneValid {
                Text("请输入有效的 11 位手机号")
                    .font(ThemeManager.Typography.caption)
                    .foregroundStyle(ThemeManager.Colors.danger)
            }
        }
        // 不自动聚焦：键盘会盖住底部的「用户协议 / 隐私政策」，
        // 而"登录即表示同意"的告知必须与操作同屏可见（审核 5.1.1）。
    }

    // MARK: 验证码

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.md) {
            HStack {
                Text("验证码已发送至 \(SafeLog.maskedPhone(phoneNumber))")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.textSecondary)
                Spacer()
                Button("修改") {
                    step = .phone
                    code = ""
                    phoneFieldFocused = true
                }
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.primary)
            }

            OTPInputField(code: $code, isFocused: $codeFieldFocused)

            HStack {
                Spacer()
                Button {
                    resend()
                } label: {
                    Text(resendRemaining > 0 ? "\(resendRemaining)s 后可重发" : "重新发送")
                        .font(ThemeManager.Typography.caption)
                }
                .disabled(resendRemaining > 0 || authService.isLoading)
                .foregroundStyle(resendRemaining > 0
                                 ? ThemeManager.Colors.textSecondary
                                 : ThemeManager.Colors.primary)
            }
        }
        .onAppear { codeFieldFocused = true }
    }

    // MARK: 按钮

    private var primaryButton: some View {
        Button {
            if step == .phone { requestCode() } else { submitCode() }
        } label: {
            HStack(spacing: ThemeManager.Spacing.sm) {
                if authService.isLoading {
                    ProgressView().tint(.white)
                }
                Text(step == .phone ? "获取验证码" : "登录")
                    .font(ThemeManager.Typography.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                LinearGradient(
                    colors: [ThemeManager.Colors.gradientStart, ThemeManager.Colors.gradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            .opacity(isPrimaryEnabled ? 1 : 0.5)
        }
        .disabled(!isPrimaryEnabled || authService.isLoading)
        .buttonStyle(PressableStyle())
    }

    private var isPrimaryEnabled: Bool {
        step == .phone ? isPhoneValid : isCodeComplete
    }

    private var biometricButton: some View {
        Button {
            Task { await runBiometrics() }
        } label: {
            Label("使用面容 ID 登录", systemImage: "faceid")
                .font(ThemeManager.Typography.subheadline)
                .foregroundStyle(ThemeManager.Colors.primary)
                .padding(.vertical, ThemeManager.Spacing.sm)
        }
        .disabled(isBiometricRunning)
    }

    /// 内测免登录入口。
    ///
    /// 只在 Info.plist 里 `RCAllowBetaSkipAuth = true` 时出现（默认 false）。
    ///
    /// ## 为什么文案要这么啰嗦
    ///
    /// 这条路径**不做任何冒充**：不假装发了验证码、不编手机号。
    /// 用户是看着「内测版本 · 跳过登录」这几个字点进去的，
    /// 所以进入后他看到「数据仅存本机」不会觉得被欺骗。
    ///
    /// 反过来，如果只写一个「跳过」，用户会以为自己注册了账号 ——
    /// 等他换手机发现数据全没了，那时再解释就晚了。
    private var betaSkipButton: some View {
        VStack(spacing: 6) {
            Divider()
                .padding(.vertical, ThemeManager.Spacing.sm)

            Button {
                authService.skipAuthForBeta()
            } label: {
                Text("内测版本 · 跳过登录")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundStyle(ThemeManager.Colors.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint("不注册账号，直接进入。所有数据只保存在这台设备上")

            Text("内测期间不收集手机号。你的数据只保存在这台设备上，卸载即丢失。")
                .font(.caption2)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, ThemeManager.Spacing.sm)
    }

    private var demoLoginButton: some View {
        VStack(spacing: 4) {
            Button("进入演示模式") {
                Task {
                    await authService.requestCode(phone: "13800000000")
                    await authService.verifyCode(phone: "13800000000", code: "000000")
                }
            }
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.textSecondary)
            Text("仅调试构建可见，不连接任何服务")
                .font(.caption2)
                .foregroundStyle(ThemeManager.Colors.textSecondary)
        }
        .padding(.top, ThemeManager.Spacing.sm)
    }

    private func errorBanner(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: ThemeManager.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ThemeManager.Colors.danger)
            Text(error.localizedDescription)
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textPrimary)
            Spacer()
        }
        .padding(ThemeManager.Spacing.md)
        .background(ThemeManager.Colors.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: 法律条款

    private var legalFooter: some View {
        VStack(spacing: ThemeManager.Spacing.sm) {
            Text("登录即表示同意")
                .font(ThemeManager.Typography.caption)
                .foregroundStyle(ThemeManager.Colors.textSecondary)

            HStack(spacing: 4) {
                Button("用户协议") { showLegal = .terms }
                Text("和").foregroundStyle(ThemeManager.Colors.textSecondary)
                Button("隐私政策") { showLegal = .privacy }
            }
            .font(ThemeManager.Typography.caption)
            .foregroundStyle(ThemeManager.Colors.primary)
        }
    }

    // MARK: 动作

    private func requestCode() {
        guard isPhoneValid else { return }
        Task {
            await authService.requestCode(phone: phoneNumber)
            guard authService.error == nil else { return }
            step = .code
            code = ""
            resendRemaining = 60
        }
    }

    private func submitCode() {
        guard isCodeComplete, !authService.isLoading else { return }
        codeFieldFocused = false
        Task {
            await authService.verifyCode(phone: phoneNumber, code: code)
            if authService.isAuthenticated {
                Telemetry.shared.track(.loginCompleted)
            }
        }
    }

    private func resend() {
        Task {
            await authService.requestCode(phone: phoneNumber)
            if authService.error == nil { resendRemaining = 60 }
        }
    }

    private func runBiometrics() async {
        isBiometricRunning = true
        defer { isBiometricRunning = false }
        do {
            let success = try await authService.authenticateWithBiometrics()
            if success {
                await authService.restoreSessionIfNeeded()
                if !authService.isAuthenticated {
                    authService.error = .invalidCredentialsFallback
                }
            }
        } catch {
            authService.error = .biometricUnavailable
        }
    }
}

// MARK: - 验证码输入
//
// 单个隐藏 TextField 承载输入 + 6 个纯展示格。
// 好处：系统短信验证码可以一次性自动填充（`.oneTimeCode`），粘贴整段也能生效，
// 不会出现「输一位就丢焦点、键盘收起」的问题。

struct OTPInputField: View {
    @Binding var code: String
    @FocusState.Binding var isFocused: Bool

    private let length = 6

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .frame(height: 56)
                .opacity(0.001)          // 保留可点区域，但不参与视觉
                .accessibilityLabel("验证码")
                .accessibilityHint("六位数字，可粘贴或等待自动填充")

            HStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(0..<length, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        let position = code.index(code.startIndex, offsetBy: index)
        return String(code[position])
    }

    private func digitBox(at index: Int) -> some View {
        let character = digit(at: index)
        let isActive = isFocused && index == min(code.count, length - 1)
        return Text(character)
            .font(ThemeManager.Typography.title2)
            .foregroundStyle(ThemeManager.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(ThemeManager.Colors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeManager.Radius.md, style: .continuous)
                    .strokeBorder(
                        isActive ? ThemeManager.Colors.primary : ThemeManager.Colors.border,
                        lineWidth: isActive ? 2 : 1
                    )
            )
    }
}

// MARK: - 兼容：AuthError 占位
//
// 生物识别成功但本地没有有效会话时使用（说明用户从未用该设备登录过）。
extension AppError {
    static var invalidCredentialsFallback: AppError { .keychainFailed("此设备还没有可用的登录记录") }
}
