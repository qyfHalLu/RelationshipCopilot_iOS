import SwiftUI
import LocalAuthentication

@Observable
class AuthenticationService {
    var isAuthenticated = false
    var currentUser: User?
    var isLoading = false
    var error: AuthenticationError?
    
    private let keychain = SecureStorageService.shared
    
    // MARK: - 登录
    func login(phone: String) {
        isLoading = true
        
        // 模拟登录过程
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.currentUser = User(phone: phone)
            self.isAuthenticated = true
            self.isLoading = false
            
            // 保存登录状态
            try? self.keychain.save(key: "auth_token", value: "mock_token_\(phone)")
        }
    }
    
    // MARK: - 退出登录
    func logout() {
        currentUser = nil
        isAuthenticated = false
        
        // 清除登录状态
        try? keychain.delete(key: "auth_token")
    }
    
    // MARK: - 生物识别认证
    func authenticateWithBiometrics() async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        
        // 检查生物识别是否可用
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        ) else {
            throw AuthenticationError.biometricNotAvailable
        }
        
        let reason = "使用Face ID解锁Relationship Copilot"
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            return success
        } catch {
            throw AuthenticationError.biometricFailed(error)
        }
    }
    
    // MARK: - 检查登录状态
    func checkAuthStatus() {
        if let token = try? keychain.retrieve(key: "auth_token") {
            // 验证token有效性
            isAuthenticated = true
        }
    }
}

// MARK: - 认证错误
enum AuthenticationError: Error {
    case biometricNotAvailable
    case biometricFailed(Error)
    case invalidCredentials
    case networkError
    case unknown
}

// MARK: - 安全存储服务
class SecureStorageService {
    static let shared = SecureStorageService()
    
    func save(key: String, value: String) throws {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStorageError.saveFailed
        }
    }
    
    func retrieve(key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw SecureStorageError.retrieveFailed
        }
        
        return value
    }
    
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

enum SecureStorageError: Error {
    case saveFailed
    case retrieveFailed
    case deleteFailed
}
