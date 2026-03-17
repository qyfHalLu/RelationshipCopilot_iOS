import SwiftUI
import LocalAuthentication

struct AuthenticationView: View {
    @Environment(AuthenticationService.self) private var authService
    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var showVerification = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景渐变
                LinearGradient(
                    colors: [
                        ThemeManager.Colors.gradientStart.opacity(0.1),
                        ThemeManager.Colors.gradientEnd.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: ThemeManager.Spacing.xxl) {
                    // Logo和标题
                    VStack(spacing: ThemeManager.Spacing.lg) {
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(ThemeManager.Colors.primary)
                            .symbolEffect(.pulse)
                        
                        Text("关系副驾")
                            .font(ThemeManager.Typography.largeTitle)
                            .foregroundColor(ThemeManager.Colors.textPrimary)
                        
                        Text("AI驱动的智能关系管理")
                            .font(ThemeManager.Typography.body)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                    }
                    .padding(.top, 60)
                    
                    // 登录表单
                    VStack(spacing: ThemeManager.Spacing.lg) {
                        if !showVerification {
                            PhoneInputField(
                                phoneNumber: $phoneNumber,
                                isLoading: $isLoading
                            )
                        } else {
                            VerificationCodeField(
                                code: $verificationCode,
                                phoneNumber: phoneNumber,
                                isLoading: $isLoading
                            )
                        }
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.danger)
                        }
                        
                        Button(action: {
                            if showVerification {
                                verifyCode()
                            } else {
                                sendCode()
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                }
                                
                                Text(showVerification ? "验证" : "获取验证码")
                                    .font(ThemeManager.Typography.headline)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                LinearGradient(
                                    colors: [ThemeManager.Colors.gradientStart, ThemeManager.Colors.gradientEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(ThemeManager.Radius.lg)
                            .shadow(ThemeManager.Shadows.md)
                        }
                        .disabled(isLoading || !isFormValid)
                        .opacity(isFormValid ? 1 : 0.6)
                    }
                    .padding(.horizontal, ThemeManager.Spacing.lg)
                    
                    // 生物识别登录
                    BiometricLoginButton {
                        authenticateWithBiometrics()
                    }
                    
                    Spacer()
                    
                    // 协议说明
                    VStack(spacing: ThemeManager.Spacing.sm) {
                        Text("登录即表示同意")
                            .font(ThemeManager.Typography.caption)
                            .foregroundColor(ThemeManager.Colors.textSecondary)
                        
                        HStack(spacing: 4) {
                            Button("用户协议") {}
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.primary)
                            
                            Text("和")
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.textSecondary)
                            
                            Button("隐私政策") {}
                                .font(ThemeManager.Typography.caption)
                                .foregroundColor(ThemeManager.Colors.primary)
                        }
                    
                    // 跳过登录 - 仅用于测试
                    Button("跳过登录") {
                        authService.login(phone: "test_user")
                    }
                    .font(ThemeManager.Typography.caption)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
                    .padding(.top, ThemeManager.Spacing.md)
                    }
                    .padding(.bottom, ThemeManager.Spacing.lg)
                }
            }
        }
    }
    
    private var isFormValid: Bool {
        if showVerification {
            return verificationCode.count == 6
        } else {
            return phoneNumber.count == 11
        }
    }
    
    private func sendCode() {
        isLoading = true
        
        // 模拟发送验证码
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isLoading = false
            withAnimation(.easeInOut) {
                showVerification = true
            }
        }
    }
    
    private func verifyCode() {
        isLoading = true
        
        // 模拟验证
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isLoading = false
            authService.login(phone: phoneNumber)
        }
    }
    
    private func authenticateWithBiometrics() {
        Task {
            do {
                let success = try await authService.authenticateWithBiometrics()
                if success {
                    authService.login(phone: "biometric_user")
                }
            } catch {
                errorMessage = "生物识别失败"
            }
        }
    }
}

// MARK: - 手机号输入
struct PhoneInputField: View {
    @Binding var phoneNumber: String
    @Binding var isLoading: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            Text("手机号")
                .font(ThemeManager.Typography.subheadline)
                .foregroundColor(ThemeManager.Colors.textSecondary)
            
            HStack {
                Text("+86")
                    .font(ThemeManager.Typography.body)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
                    .padding(.horizontal, ThemeManager.Spacing.sm)
                
                Divider()
                
                TextField("请输入手机号", text: $phoneNumber)
                    .font(ThemeManager.Typography.body)
                    .keyboardType(.numberPad)
                    .disabled(isLoading)
            }
            .padding(ThemeManager.Spacing.md)
            .background(Color.white)
            .cornerRadius(ThemeManager.Radius.md)
            .shadow(ThemeManager.Shadows.sm)
        }
    }
}

// MARK: - 验证码输入
struct VerificationCodeField: View {
    @Binding var code: String
    let phoneNumber: String
    @Binding var isLoading: Bool
    @State private var timeRemaining = 60
    @State private var timer: Timer?
    
    var body: some View {
        VStack(alignment: .leading, spacing: ThemeManager.Spacing.sm) {
            HStack {
                Text("验证码")
                    .font(ThemeManager.Typography.subheadline)
                    .foregroundColor(ThemeManager.Colors.textSecondary)
                
                Spacer()
                
                Button(action: resendCode) {
                    Text(timeRemaining > 0 ? "\(timeRemaining)s后重发" : "重新发送")
                        .font(ThemeManager.Typography.caption)
                        .foregroundColor(timeRemaining > 0 ? ThemeManager.Colors.textSecondary : ThemeManager.Colors.primary)
                }
                .disabled(timeRemaining > 0 || isLoading)
            }
            
            HStack(spacing: ThemeManager.Spacing.sm) {
                ForEach(0..<6, id: \.self) { index in
                    VerificationDigitBox(
                        index: index,
                        code: $code
                    )
                }
            }
            .onAppear {
                startTimer()
            }
            .onDisappear {
                timer?.invalidate()
            }
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if timeRemaining > 0 {
                timeRemaining -= 1
            } else {
                timer?.invalidate()
            }
        }
    }
    
    private func resendCode() {
        timeRemaining = 60
        startTimer()
    }
}

// MARK: - 验证码数字框
struct VerificationDigitBox: View {
    let index: Int
    @Binding var code: String
    @FocusState private var isFocused: Bool
    
    var body: some View {
        TextField("", text: Binding(
            get: { getDigit(at: index) },
            set: { setDigit($0, at: index) }
        ))
        .font(.system(size: 24, weight: .bold))
        .multilineTextAlignment(.center)
        .keyboardType(.numberPad)
        .frame(width: 48, height: 56)
        .background(Color.white)
        .cornerRadius(ThemeManager.Radius.md)
        .shadow(ThemeManager.Shadows.sm)
        .focused($isFocused)
        .onChange(of: code) { _ in
            if code.count > index {
                isFocused = false
            }
        }
    }
    
    private func getDigit(at index: Int) -> String {
        if code.count > index {
            let start = code.index(code.startIndex, offsetBy: index)
            return String(code[start])
        }
        return ""
    }
    
    private func setDigit(_ digit: String, at index: Int) {
        if digit.count == 1 {
            if code.count > index {
                let start = code.index(code.startIndex, offsetBy: index)
                code.replaceSubrange(start...start, with: digit)
            } else {
                code.append(digit)
            }
        }
    }
}

// MARK: - 生物识别登录按钮
struct BiometricLoginButton: View {
    let action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: ThemeManager.Spacing.sm) {
                Image(systemName: "faceid")
                    .font(.title3)
                
                Text("使用 Face ID 登录")
                    .font(ThemeManager.Typography.subheadline)
            }
            .foregroundColor(ThemeManager.Colors.primary)
            .padding(.vertical, ThemeManager.Spacing.md)
        }
        .scaleEffect(isPressed ? 0.96 : 1.0)
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
