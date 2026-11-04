//
//  EndpointConfiguration.swift
//  RelationshipCopilot
//
//  修复报告 D1（P0，已发生的安全事件）：
//  原实现把 SophNet 的 Bearer 密钥**硬编码在源码** `AIService.swift:277`，提交于 432646f，
//  在公开仓库暴露约 7.5 个月。任何提取 IPA 的人都能拿到并在所有者账上调用。
//
//  本文件的原则：**客户端永不携带第三方模型密钥**。
//   1. 首选「自有代理」：App → 自有服务端 → SophNet。密钥只在服务端。
//   2. 仅在调试构建允许「直连 + Keychain 密钥」：密钥由开发者手动写入 Keychain，
//      不进入源码、不进入 IPA、不进入 git。
//   3. 两者都未配置时，AI 功能明确降级为「未配置」状态，UI 给出可解释提示，
//      绝不静默失败、也绝不内置任何默认密钥。
//

import Foundation

/// AI 接入方式。
enum AIEndpointMode: Equatable {
    /// 走自有代理（推荐，生产唯一形态）
    case proxy(baseURL: URL)
    /// 调试：直连模型厂商，密钥取自 Keychain
    case direct(baseURL: URL, apiKey: String)
    /// 未配置：AI 功能不可用
    case unconfigured

    var isAvailable: Bool {
        if case .unconfigured = self { return false }
        return true
    }
}

/// 配置读取器。所有值都来自 Info.plist 或 Keychain，源码中无任何密钥。
struct EndpointConfiguration {

    /// Info.plist 键：自有代理根地址，例如 `https://api.example.com`
    static let proxyBaseURLKey = "RCProxyBaseURL"
    /// Info.plist 键：调试构建允许的直连地址（默认 SophNet）
    static let directBaseURLKey = "RCDirectBaseURL"
    /// Info.plist 键：直连时使用的模型标识（例如 SophNet 控制台里给出的模型名）
    static let directModelKey = "RCDirectModelName"
    /// Keychain 中存放调试直连密钥的 account
    static let directKeychainAccount = "rc.ai.direct_api_key"
    /// Keychain 中存放**代理共享令牌**的 account。
    ///
    /// 与直连密钥分开存：前者是"证明我是这个 App"，后者是"模型厂商的密钥"。
    /// 混用一个 account 会让两种模式的配置互相覆盖 —— 切模式时静默失效。
    static let proxyTokenKeychainAccount = "rc.ai.proxy_token"
    /// 是否允许直连（仅 Debug 生效，Release 强制走代理）
    static let allowDirectInDebugKey = "RCAllowDirectKeyInDebug"
    /// Info.plist 键：是否开放「内测免登录」（仅内测构建置 true）
    static let allowBetaSkipAuthKey = "RCAllowBetaSkipAuth"

    /// 直连模型名的兜底值。
    ///
    /// 保留兜底是为了兼容早期只在代码里写死模型的构建；生产配置应以
    /// `RCDirectModelName` 为准，换模型不必改代码、不必重新发版。
    static let defaultDirectModel = "Kimi-K2.5"

    /// 从 Info.plist 读取直连模型名。
    static func directModel(bundle: Bundle = .main) -> String {
        if let name = bundle.object(forInfoDictionaryKey: directModelKey) as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return defaultDirectModel
    }

    /// 解析当前接入方式。
    ///
    /// - Parameter keychain: 可注入，便于测试。
    static func resolve(
        bundle: Bundle = .main,
        keychain: SecureStoring = SecureStorageService.shared,
        isDebugBuild: Bool = _isDebugAssertConfiguration()
    ) -> AIEndpointMode {

        // 1) 代理优先（生产形态）
        if let proxyString = bundle.object(forInfoDictionaryKey: proxyBaseURLKey) as? String,
           !proxyString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let proxyURL = URL(string: proxyString) {
            return .proxy(baseURL: proxyURL)
        }

        // 2) 调试直连（仅 Debug，且密钥必须已在 Keychain）
        //
        // 双保险：
        //   · `#if DEBUG` 让 Release 二进制里**根本不存在**构造 `.direct` 的代码路径；
        //   · `isDebugBuild` 参数让单测可以在 Debug 构建下模拟 Release 行为。
        // 只留任何一个都不够 —— 前者防"某次重构删了判断"，后者防"测试形同虚设"。
        // Info.plist 里的 `RCAllowDirectKeyInDebug` 是第三个开关：
        // 它即使为 true 也不足以启用直连，必须三者同时成立。
        #if DEBUG
        if isDebugBuild {
            let directAllowed = (bundle.object(forInfoDictionaryKey: allowDirectInDebugKey) as? Bool) ?? false
            if directAllowed,
               let directString = bundle.object(forInfoDictionaryKey: directBaseURLKey) as? String,
               let directURL = URL(string: directString),
               let apiKey = try? keychain.retrieve(key: directKeychainAccount),
               !apiKey.isEmpty {
                return .direct(baseURL: directURL, apiKey: apiKey)
            }
        }
        #endif

        return .unconfigured
    }

    /// 供设置页展示的诊断信息（不包含密钥本身）。
    static func diagnostics(for mode: AIEndpointMode) -> String {
        switch mode {
        case .proxy(let url):
            return "已通过自有服务端接入（\(url.host() ?? "unknown")）"
        case .direct(let url, _):
            return "调试直连（\(url.host() ?? "unknown")）· 仅限本机构建"
        case .unconfigured:
            return "未配置 AI 服务"
        }
    }

    /// 内测期是否开放「免登录进入」。
    ///
    /// ## 这个开关为什么存在
    ///
    /// Release 构建里没有真实登录后端时，`UnconfiguredAuthProvider` 会让
    /// 所有登录请求返回 503 —— 内测用户能看到登录页，但**永远进不去**。
    /// 这不是 bug，是刻意不伪造登录成功；但没有真后端的阶段又必须能测。
    ///
    /// 所以给一个显式、可关闭、且必须自我声明的旁路：
    ///
    /// - **默认 false**。上架前不填或填 false，行为回到"登录服务未配置"。
    /// - 只在 Info.plist 里显式写 `RCAllowBetaSkipAuth = true` 才生效，
    ///   因此不会因为某次重构而意外打开。
    /// - 进入后 `isDemoSession` 为 true，界面上明确标注
    ///   「内测版本 · 数据仅存本机」，不假装是真实账号。
    ///
    /// **不做的事**：不伪造手机号、不发假验证码、不让登录看起来成功了。
    /// 用户是点了一个写着"内测期间跳过登录"的按钮进来的，他知道自己在什么状态里。
    static func allowsBetaSkipAuth(bundle: Bundle = .main) -> Bool {
        (bundle.object(forInfoDictionaryKey: allowBetaSkipAuthKey) as? Bool) ?? false
    }
}
