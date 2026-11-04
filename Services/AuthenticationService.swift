import SwiftUI
import LocalAuthentication
import CryptoKit

// MARK: - 认证服务
//
// 修复报告 D6 / D7 / A4：
//  - D6：`SecureStorageService.save` 把 `kSecValueData`（值属性，非搜索属性）放进
//        `SecItemDelete` 的查询里，且丢弃返回码 → 二次保存会因 DuplicateItem 静默失败，
//        表现为"换了账号仍是旧身份"。现改为 `SecItemUpdate` 优先、`SecItemAdd` 兜底，
//        并带 `kSecAttrService` 做命名空间隔离。
//  - D7：`checkAuthStatus()` 全仓库零调用，冷启动必然回到登录页。现在由 App 启动时调用，
//        并真正恢复 `currentUser`。
//  - A4：登录失败不再静默，错误统一走 `AppError`。
//
// 说明（诚实边界）：目前没有后端，验证码只做**格式**校验，不做真实性校验。
// 为避免"假登录"被误认为已实现，生产构建下必须注入真实的 `AuthProviding`；
// 内置的 `LocalDevAuthProvider` 仅在 DEBUG 生效，且 UI 上明确标注。
//

/// 认证提供方。生产环境应注入对接自有服务端的实现。
protocol AuthProviding: Sendable {
    /// 请求发送验证码。
    func requestCode(phone: String) async throws
    /// 校验验证码并返回会话令牌。
    func verifyCode(phone: String, code: String) async throws -> AuthSession
    /// 恢复既有会话。
    func restoreSession() async throws -> AuthSession?
    /// 注销。
    func signOut() async throws
}

struct AuthSession: Sendable, Equatable {
    let phone: String
    let token: String
    let displayName: String?
}

/// 仅用于开发与演示的本地实现：不联网，验证码格式合法即通过。
/// 生产构建中不得使用（`AuthenticationService` 会在非 DEBUG 下拒绝它）。
struct LocalDevAuthProvider: AuthProviding {
    func requestCode(phone: String) async throws {
        guard Validation.isValidPhone(phone) else { throw AppError.invalidPhone }
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func verifyCode(phone: String, code: String) async throws -> AuthSession {
        guard Validation.isValidPhone(phone) else { throw AppError.invalidPhone }
        guard Validation.isValidCode(code) else { throw AppError.invalidCode }
        try await Task.sleep(nanoseconds: 400_000_000)
        // 令牌用随机串而非手机号，避免把手机号当凭证使用
        let token = UUID().uuidString + "-" + UUID().uuidString
        return AuthSession(phone: phone, token: token, displayName: nil)
    }

    func restoreSession() async throws -> AuthSession? { nil }

    func signOut() async throws {}
}

@Observable
@MainActor
final class AuthenticationService {

    private(set) var isAuthenticated = false
    private(set) var currentUser: User?
    private(set) var isLoading = false
    private(set) var isRestoring = true
    var error: AppError?

    /// 当前是否为「本地演示登录」（用于 UI 明确标注，避免把演示态当成真实账号）。
    private(set) var isDemoSession = false

    private let keychain: SecureStoring
    private let provider: AuthProviding

    private enum Keys {
        static let token = "auth_token"
        static let phone = "auth_phone"
        static let demo = "auth_is_demo"
    }

    init(
        keychain: SecureStoring = SecureStorageService.shared,
        provider: AuthProviding? = nil
    ) {
        self.keychain = keychain
        if let provider {
            self.provider = provider
        } else {
            #if DEBUG
            self.provider = LocalDevAuthProvider()
            #else
            // 生产构建必须注入真实 provider；未注入时保持未配置状态，
            // 由 UI 提示"登录服务未配置"，而不是伪造登录成功。
            self.provider = UnconfiguredAuthProvider()
            #endif
        }
    }

    // MARK: - 登录

    func requestCode(phone rawPhone: String) async {
        let phone = Validation.normalizePhone(rawPhone)
        guard Validation.isValidPhone(phone) else {
            error = .invalidPhone
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await provider.requestCode(phone: phone)
            error = nil
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .serverError(-1)
        }
    }

    func verifyCode(phone rawPhone: String, code: String) async {
        let phone = Validation.normalizePhone(rawPhone)
        guard Validation.isValidPhone(phone) else {
            error = .invalidPhone
            return
        }
        guard Validation.isValidCode(code) else {
            error = .invalidCode
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let session = try await provider.verifyCode(phone: phone, code: code)
            persist(session: session, isDemo: await isUsingDevProvider())
            error = nil
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .serverError(-1)
        }
    }

    // MARK: - 生物识别

    func authenticateWithBiometrics() async throws -> Bool {
        let context = LAContext()
        var evalError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evalError) else {
            throw AppError.biometricUnavailable
        }

        let reason = "解锁你的关系记录"
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch {
            throw AppError.biometricUnavailable
        }
    }

    /// 是否具备可用的生物识别（用于决定是否展示 Face ID 按钮）。
    var canUseBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: - 会话恢复

    /// 冷启动时恢复登录态。修复报告 D7：此前该方法从未被调用。
    func restoreSessionIfNeeded() async {
        defer { isRestoring = false }
        guard !isAuthenticated else { return }

        // 1) 优先由 provider 校验（有后端时应请求 /me）
        if let session = try? await provider.restoreSession() {
            persist(session: session, isDemo: false)
            return
        }

        // 2) 退回本地凭证（离线可用，避免无网就踢回登录页）
        guard let token = try? keychain.retrieve(key: Keys.token), !token.isEmpty,
              let phone = try? keychain.retrieve(key: Keys.phone), !phone.isEmpty else {
            return
        }
        let demoFlag = (try? keychain.retrieve(key: Keys.demo)) == "1"
        let user = User(phone: phone)
        currentUser = user
        isAuthenticated = true
        isDemoSession = demoFlag
        AppLog.auth.info("Restored session from keychain, demo=\(demoFlag, privacy: .public)")
    }

    // MARK: - 登出

    func logout() {
        currentUser = nil
        isAuthenticated = false
        isDemoSession = false
        try? keychain.delete(key: Keys.token)
        try? keychain.delete(key: Keys.phone)
        try? keychain.delete(key: Keys.demo)
        Task { try? await provider.signOut() }
    }

    // MARK: - 内测免登录

    /// 内测期是否允许跳过登录。见 `EndpointConfiguration.allowsBetaSkipAuth`。
    var canSkipAuthForBeta: Bool {
        EndpointConfiguration.allowsBetaSkipAuth()
    }

    /// 内测免登录。
    ///
    /// ## 与 `debugForceLogin` 的区别
    ///
    /// 后者是界面核验用的后门，只在 DEBUG 存在、写入假手机号、
    /// 且不向用户解释任何事情。
    ///
    /// 这个方法是**面向真实内测用户**的：Release 可用、必须由 Info.plist
    /// 显式开启、进入后 `isDemoSession = true` 且界面标注「内测版本 · 数据仅存本机」。
    ///
    /// 之所以要单独写而不是把 `debugForceLogin` 放开到 Release：
    /// 那个方法的语义是"自动化脚本要一个确定的身份"，一旦让它对用户可见，
    /// 假手机号 `13800000000` 就会出现在真实用户的「我的」页面里。
    func skipAuthForBeta() {
        let session = AuthSession(
            phone: "",
            token: "beta-session-" + UUID().uuidString,
            displayName: nil
        )
        persist(session: session, isDemo: true)
        isRestoring = false
        Telemetry.shared.track(.loginCompleted)
    }

    // MARK: - 私有

    private func persist(session: AuthSession, isDemo: Bool) {
        do {
            try keychain.save(key: Keys.token, value: session.token)
            try keychain.save(key: Keys.phone, value: session.phone)
            try keychain.save(key: Keys.demo, value: isDemo ? "1" : "0")
        } catch {
            // 存不进 Keychain 也允许本次会话继续，但要记录（下次启动需重新登录）
            AppLog.auth.error("Failed to persist session: \(String(describing: error), privacy: .public)")
            self.error = .keychainFailed("会话保存失败")
        }
        let user = User(phone: session.phone)
        currentUser = user
        isAuthenticated = true
        isDemoSession = isDemo
    }

    private func isUsingDevProvider() async -> Bool {
        #if DEBUG
        return provider is LocalDevAuthProvider
        #else
        return false
        #endif
    }

    #if DEBUG
    /// 仅供界面核验脚本使用（见 `UITestSupport`）。Release 构建中不存在。
    func debugForceLogin(phone: String = "13800000000") {
        let session = AuthSession(phone: phone, token: "ui-test-session", displayName: nil)
        persist(session: session, isDemo: true)
        isRestoring = false
    }
    #endif
}

/// 未配置后端时的占位 provider：明确失败，绝不伪造成功。
struct UnconfiguredAuthProvider: AuthProviding {
    func requestCode(phone: String) async throws {
        throw AppError.serverError(503)
    }
    func verifyCode(phone: String, code: String) async throws -> AuthSession {
        throw AppError.serverError(503)
    }
    func restoreSession() async throws -> AuthSession? { nil }
    func signOut() async throws {}
}

// MARK: - 认证错误（保留以兼容既有引用）
enum AuthenticationError: Error {
    case biometricNotAvailable
    case biometricFailed(Error)
    case invalidCredentials
    case networkError
    case unknown
}

// MARK: - 安全存储服务
//
// 修复报告 D6：原先只按 account 检索、缺 `kSecAttrService`，删除查询里混入值属性，
// 且所有失败都被 `try?` 吞掉。现在：带 service 命名空间；更新优先于新增；返回码受检。
//
// 抽出 `SecureStoring` 协议是为了让 `EndpointConfiguration.resolve` 可被测试注入。
// 这不仅是测试便利：接入方式的解析规则里有一条「Release 绝不能直连」的硬约束，
// 它必须被测试锁死（见 EndpointConfigurationTests），否则某次重构去掉 `isDebugBuild`
// 判断就会静默把密钥打进 IPA —— 这个仓库已经发生过一次泄露事故。
protocol SecureStoring {
    func save(key: String, value: String) throws
    func retrieve(key: String) throws -> String
    func delete(key: String) throws
    func exists(key: String) -> Bool
}

final class SecureStorageService: SecureStoring {
    static let shared = SecureStorageService()

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.relationshipcopilot.app") {
        self.service = service
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AppError.keychainFailed("编码失败")
        }

        let query = baseQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppError.keychainFailed("写入失败(\(addStatus))")
            }
            return
        }

        throw AppError.keychainFailed("更新失败(\(updateStatus))")
    }

    func retrieve(key: String) throws -> String {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AppError.keychainFailed("读取失败(\(status))")
        }
        return value
    }

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainFailed("删除失败(\(status))")
        }
    }

    /// 是否存在某条记录（不读取内容）。
    func exists(key: String) -> Bool {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

enum SecureStorageError: Error {
    case saveFailed
    case retrieveFailed
    case deleteFailed
}
