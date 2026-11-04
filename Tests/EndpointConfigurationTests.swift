//
//  EndpointConfigurationTests.swift
//  RelationshipCopilotTests
//
//  AI 接入方式的解析规则。
//
//  ## 为什么这份配置需要测试
//
//  这个仓库出过一次真实安全事件：API 密钥被硬编码在 `AIService.swift:277`
//  并提交到公开仓库，暴露约 7.5 个月。任何解包 IPA 的人都能拿去用。
//
//  修复后的架构是「密钥永不进源码与构建产物」，但它依赖三条规则同时成立：
//    ① 代理优先（生产唯一形态，密钥在服务端）
//    ② 直连仅 Debug 且密钥必须已在 Keychain
//    ③ 都没有时明确 unconfigured，绝不内置默认密钥
//
//  这三条只要有一条被"顺手简化"掉，缺陷就会静默回归 —— 而且回归后
//  **界面一切正常**，不会有任何报错。所以必须由测试守着。
//

import XCTest
@testable import RelationshipCopilot

final class EndpointConfigurationTests: XCTestCase {

    /// 可注入的假 Keychain。
    ///
    /// 真实 Keychain 在单测进程里不可靠（需要 entitlement、可能被系统锁定），
    /// 而这套规则又必须被测试覆盖，所以抽了 `SecureStoring` 协议来注入。
    private final class StubStore: SecureStoring {
        var storage: [String: String] = [:]

        func save(key: String, value: String) throws {
            storage[key] = value
        }

        func retrieve(key: String) throws -> String {
            guard let value = storage[key] else { throw SecureStorageError.retrieveFailed }
            return value
        }

        func delete(key: String) throws {
            storage.removeValue(forKey: key)
        }

        func exists(key: String) -> Bool {
            storage[key] != nil
        }
    }

    /// 构造一个只包含指定键值的假 Bundle。
    private final class StubBundle: Bundle, @unchecked Sendable {
        private let values: [String: Any]
        init(_ values: [String: Any]) {
            self.values = values
            super.init()
        }
        override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    }

    private func makeStore(withKey key: String? = "sk-test-key") -> StubStore {
        let store = StubStore()
        if let key {
            store.storage[EndpointConfiguration.directKeychainAccount] = key
        }
        return store
    }

    // MARK: 规则一：代理优先

    func testProxyTakesPriorityInRelease() {
        let bundle = StubBundle([
            EndpointConfiguration.proxyBaseURLKey: "https://api.example.com",
            EndpointConfiguration.directBaseURLKey: "https://direct.example.com",
            EndpointConfiguration.allowDirectInDebugKey: true
        ])
        let mode = EndpointConfiguration.resolve(
            bundle: bundle, keychain: makeStore(), isDebugBuild: false
        )
        guard case .proxy(let url) = mode else {
            return XCTFail("Release 构建必须走代理，实际：\(mode)")
        }
        XCTAssertEqual(url.absoluteString, "https://api.example.com")
    }

    // MARK: 规则二：直连仅 Debug

    /// **这是最关键的一条。**
    ///
    /// 即使 Info.plist 允许直连、Keychain 里也有密钥，
    /// Release 构建也绝不能走直连 —— 否则密钥会随 IPA 分发，
    /// 正是历史上发生过的那个事故。
    func testDirectIsImpossibleInReleaseEvenIfConfigured() {
        let bundle = StubBundle([
            EndpointConfiguration.proxyBaseURLKey: "",
            EndpointConfiguration.directBaseURLKey: "https://www.sophnet.com/api/open-apis/v1/chat/completions",
            EndpointConfiguration.allowDirectInDebugKey: true
        ])
        let mode = EndpointConfiguration.resolve(
            bundle: bundle, keychain: makeStore(), isDebugBuild: false
        )
        guard case .unconfigured = mode else {
            return XCTFail(
                "Release 构建竟然启用了直连（\(mode)）—— 密钥会随 IPA 分发。"
                + "这是本仓库已经发生过一次的安全事件。"
            )
        }
    }

    func testDirectWorksInDebugWhenKeyPresent() {
        let bundle = StubBundle([
            EndpointConfiguration.directBaseURLKey: "https://www.sophnet.com/api/open-apis/v1/chat/completions",
            EndpointConfiguration.allowDirectInDebugKey: true
        ])
        let mode = EndpointConfiguration.resolve(
            bundle: bundle, keychain: makeStore(), isDebugBuild: true
        )
        guard case .direct(let url, let key) = mode else {
            return XCTFail("Debug + 有密钥时应走直连，实际：\(mode)")
        }
        XCTAssertEqual(url.absoluteString, "https://www.sophnet.com/api/open-apis/v1/chat/completions")
        XCTAssertEqual(key, "sk-test-key")
    }

    /// 钥匙串里没有密钥时，即使允许直连也必须退回未配置。
    /// 否则会拿着空 key 发请求，得到一个看不懂的 401。
    func testDirectRequiresKeyInKeychain() {
        let bundle = StubBundle([
            EndpointConfiguration.directBaseURLKey: "https://www.sophnet.com/api/open-apis/v1/chat/completions",
            EndpointConfiguration.allowDirectInDebugKey: true
        ])
        let mode = EndpointConfiguration.resolve(
            bundle: bundle, keychain: makeStore(withKey: nil), isDebugBuild: true
        )
        guard case .unconfigured = mode else {
            return XCTFail("没有密钥时不应走直连，实际：\(mode)")
        }
    }

    /// Info.plist 里显式关闭直连时，即使 Debug 也不许走。
    func testDirectRespectsExplicitOptOut() {
        let bundle = StubBundle([
            EndpointConfiguration.directBaseURLKey: "https://www.sophnet.com/api/open-apis/v1/chat/completions",
            EndpointConfiguration.allowDirectInDebugKey: false
        ])
        let mode = EndpointConfiguration.resolve(
            bundle: bundle, keychain: makeStore(), isDebugBuild: true
        )
        guard case .unconfigured = mode else {
            return XCTFail("显式关闭直连后仍走了直连，实际：\(mode)")
        }
    }

    // MARK: 规则三：不内置默认密钥

    /// 完全没配置时必须是 unconfigured —— 绝不允许存在"内置兜底密钥"这种设计。
    func testNothingConfiguredYieldsUnconfigured() {
        let mode = EndpointConfiguration.resolve(
            bundle: StubBundle([:]), keychain: makeStore(withKey: nil), isDebugBuild: true
        )
        guard case .unconfigured = mode else {
            return XCTFail("无配置时必须明确不可用，实际：\(mode)")
        }
    }

    // MARK: 诊断信息

    /// 诊断文案**不得**包含密钥本身，否则设置页会把密钥显示在屏幕上。
    func testDiagnosticsNeverLeakKey() {
        let mode = AIEndpointMode.direct(
            baseURL: URL(string: "https://www.sophnet.com/api/open-apis/v1/chat/completions")!,
            apiKey: "sk-super-secret-value"
        )
        let text = EndpointConfiguration.diagnostics(for: mode)
        XCTAssertFalse(text.contains("sk-super-secret-value"), "诊断信息泄露了密钥")
        XCTAssertTrue(text.contains("sophnet"), "诊断应能看出接的是哪家")
    }

    // MARK: 模型名

    /// 模型名从配置读取，而不是写死在代码里。
    /// 写死意味着换模型要改代码、重新编译、重新分发。
    func testModelNameIsConfigurable() {
        XCTAssertEqual(
            EndpointConfiguration.directModel(bundle: StubBundle([
                EndpointConfiguration.directModelKey: "DeepSeek-V3-Fast"
            ])),
            "DeepSeek-V3-Fast"
        )
    }

    func testModelNameFallsBackWhenBlank() {
        XCTAssertEqual(
            EndpointConfiguration.directModel(bundle: StubBundle([
                EndpointConfiguration.directModelKey: "   "
            ])),
            EndpointConfiguration.defaultDirectModel
        )
    }

    // MARK: 内测免登录开关

    /// 缺省必须是**关闭**。
    ///
    /// 这个开关让内测用户可以绕过登录直接进入 App。
    /// 如果哪次重构让它默认打开，上架版本就会带着一个"不用登录"的后门 ——
    /// 而且因为界面一切正常，没有人会发现。
    ///
    /// 所以：没写这个键 = 关闭，写 false = 关闭，只有显式写 true 才生效。
    func testBetaSkipAuthIsOffByDefault() {
        XCTAssertFalse(
            EndpointConfiguration.allowsBetaSkipAuth(bundle: StubBundle([:])),
            "内测免登录在缺省配置下是打开的 —— 这是个后门"
        )
        XCTAssertFalse(
            EndpointConfiguration.allowsBetaSkipAuth(bundle: StubBundle([
                EndpointConfiguration.allowBetaSkipAuthKey: false
            ]))
        )
    }

    func testBetaSkipAuthOnlyWhenExplicitlyEnabled() {
        XCTAssertTrue(
            EndpointConfiguration.allowsBetaSkipAuth(bundle: StubBundle([
                EndpointConfiguration.allowBetaSkipAuthKey: true
            ]))
        )
    }

    /// 代理令牌的 Keychain account 必须与直连密钥分开。
    ///
    /// 混用同一个 account 的后果：切换接入方式时两种凭证互相覆盖。
    /// 表现是"配好了却还是 401"或"直连突然失效"，而且**没有任何报错**。
    func testProxyTokenAccountIsDistinctFromDirectKey() {
        XCTAssertNotEqual(
            EndpointConfiguration.proxyTokenKeychainAccount,
            EndpointConfiguration.directKeychainAccount
        )
    }
}

// MARK: - 上架前的闸门

/// 防"忘了关内测开关"。
///
/// ## 为什么要一条测试来盯一个 Info.plist 的值
///
/// `RCAllowBetaSkipAuth = true` 是内测期的临时后门：它让用户不登录就能进 App。
/// 这个键现在就在仓库里的 `App/Info.plist` 中，**打开的状态**。
///
/// 上架 App Store 时如果忘了改成 false，结果是：
/// 正式版 App 带一个"跳过登录"按钮，任何人点一下就能用一个伪造 token 进入。
/// 那不是安全问题（数据都在本机），但它是产品事故 —— 用户根本不会有账号。
///
/// 这条测试的作用不是"现在让它红"，而是给上架流程留一个**必须处理的显式动作**：
/// 真到要发版那天，它会是红的，而失败信息直接写着该改哪一行。
///
/// 用环境变量控制：日常开发与内测时设置 `RC_BETA_BUILD=1`，
/// 未设置（即发版流水线）时这条断言生效。
final class ReleaseGateTests: XCTestCase {

    func testBetaSkipAuthMustBeOffWhenNotExplicitlyABetaBuild() throws {
        guard ProcessInfo.processInfo.environment["RC_BETA_BUILD"] == "1" else {
            // 发版路径：读真实的 Info.plist，确认后门是关的。
            let enabled = EndpointConfiguration.allowsBetaSkipAuth()
            XCTAssertFalse(
                enabled,
                """
                App/Info.plist 里的 RCAllowBetaSkipAuth 仍是 true。
                发版前必须改成 false（或删掉这一项），否则正式包里带一个「跳过登录」后门。
                内测构建请设置环境变量 RC_BETA_BUILD=1 跳过这条断言。
                """
            )
            return
        }

        // 内测路径：确认开关确实是开的，免得内测包反而进不去。
        XCTAssertTrue(
            EndpointConfiguration.allowsBetaSkipAuth(),
            "声明为内测构建（RC_BETA_BUILD=1），但 Info.plist 里没有打开 RCAllowBetaSkipAuth"
        )
    }
}
