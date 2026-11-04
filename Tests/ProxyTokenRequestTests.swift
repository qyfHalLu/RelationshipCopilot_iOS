//
//  ProxyTokenRequestTests.swift
//  RelationshipCopilotTests
//
//  令牌链路的行为级测试：**构造 AIService 之后**写入 Keychain 的令牌，
//  必须出现在下一次真实请求的头里。
//
//  ## 为什么不能只测"读取函数"
//
//  最初的版本只断言 `store.retrieve(...)` 在写入后返回新值 —— 那是个
//  同义反复：假 Store 当然每次都返回最新值，它测的是 StubStore 而不是产品。
//
//  反向验证当场暴露了它：把读取改成"第一次读就缓存"，那个测试仍然是绿的，
//  只有 `testTokenChangeIsReflected` 报红。
//
//  所以这里改用 `URLProtocol` 拦真实请求，直接看**发出去的头**里有没有令牌。
//  这才是用户实际会遇到的路径。
//

import XCTest
@testable import RelationshipCopilot

// MARK: - 拦截器

/// 拦住所有请求，记录头，返回一个合法的空体响应。
final class RecordingURLProtocol: URLProtocol {

    /// 最近一次请求的头。`nonisolated(unsafe)` 是因为 URLProtocol 的回调
    /// 不在主线程，而这个桩只在单测里用。
    nonisolated(unsafe) static var lastHeaders: [String: String] = [:]
    nonisolated(unsafe) static var lastPath: String = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RecordingURLProtocol.lastHeaders = request.allHTTPHeaderFields ?? [:]
        RecordingURLProtocol.lastPath = request.url?.path ?? ""

        // 回一个结构合法但内容为空的响应，让调用方走到它自己的错误路径，
        // 我们不关心结果，只关心发出去的头。
        let body = Data(#"{"text":""}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 测试

final class ProxyTokenRequestTests: XCTestCase {

    private final class StubStore: SecureStoring {
        var storage: [String: String] = [:]
        func save(key: String, value: String) throws { storage[key] = value }
        func retrieve(key: String) throws -> String {
            guard let value = storage[key] else { throw SecureStorageError.retrieveFailed }
            return value
        }
        func delete(key: String) throws { storage.removeValue(forKey: key) }
        func exists(key: String) -> Bool { storage[key] != nil }
    }

    private var store: StubStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        store = StubStore()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        session = URLSession(configuration: config)

        RecordingURLProtocol.lastHeaders = [:]
        RecordingURLProtocol.lastPath = ""
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        store = nil
        super.tearDown()
    }

    @MainActor
    private func makeService() -> AIService {
        AIService(
            keychain: store,
            defaults: UserDefaults(suiteName: "ProxyTokenRequestTests")!,
            session: session,
            mode: .proxy(baseURL: URL(string: "https://proxy.test")!),
            dailyLimit: 99
        )
    }

    /// 核心用例：服务已构造完毕，**之后**才写入令牌，请求必须带上它。
    ///
    /// 这正是内测用户的真实顺序 —— App 启动时 `AIService.shared` 已经建好，
    /// 令牌是用户后来在设置页粘进去的。
    @MainActor
    func testTokenWrittenAfterInitIsSentWithNextRequest() async throws {
        let service = makeService()

        // 构造之后才写令牌
        try store.save(
            key: EndpointConfiguration.proxyTokenKeychainAccount,
            value: "beta-token-live"
        )

        _ = try? await service.quickTool(kind: .conflict, input: "她说我总在解释")

        XCTAssertEqual(
            RecordingURLProtocol.lastHeaders[AIService.proxyTokenHeader],
            "beta-token-live",
            "构造后写入的令牌没有随请求发出 —— 用户会看到「已保存」但每次都是 401"
        )
    }

    /// 令牌变更后，下一次请求必须用新值。
    @MainActor
    func testUpdatedTokenReplacesOldOne() async throws {
        try store.save(
            key: EndpointConfiguration.proxyTokenKeychainAccount,
            value: "old-token"
        )
        let service = makeService()

        try store.save(
            key: EndpointConfiguration.proxyTokenKeychainAccount,
            value: "new-token"
        )

        _ = try? await service.quickTool(kind: .conflict, input: "测试")

        XCTAssertEqual(
            RecordingURLProtocol.lastHeaders[AIService.proxyTokenHeader],
            "new-token",
            "仍在使用旧令牌"
        )
    }

    /// 没令牌时不发这个头（由服务端回 401，而不是客户端伪装成"未配置"）。
    @MainActor
    func testMissingTokenSendsNoHeader() async throws {
        let service = makeService()

        _ = try? await service.quickTool(kind: .conflict, input: "测试")

        XCTAssertNil(
            RecordingURLProtocol.lastHeaders[AIService.proxyTokenHeader],
            "没有令牌却发了这个头"
        )
    }

    /// 直连模式（调试用）不该带上内测代理令牌 —— 那条路走的是 Bearer。
    @MainActor
    func testDirectModeDoesNotSendProxyToken() async throws {
        try store.save(
            key: EndpointConfiguration.proxyTokenKeychainAccount,
            value: "beta-token-live"
        )

        let service = AIService(
            keychain: store,
            defaults: UserDefaults(suiteName: "ProxyTokenRequestTests")!,
            session: session,
            mode: .direct(baseURL: URL(string: "https://api.test/v1/chat")!, apiKey: "sk-direct"),
            dailyLimit: 99
        )

        _ = try? await service.quickTool(kind: .conflict, input: "测试")

        XCTAssertNil(
            RecordingURLProtocol.lastHeaders[AIService.proxyTokenHeader],
            "直连模式混进了代理令牌"
        )
        XCTAssertEqual(
            RecordingURLProtocol.lastHeaders["Authorization"],
            "Bearer sk-direct"
        )
    }

    // MARK: - 文案与实现的一致性

    /// 设置页那句状态文案，必须和 `proxyToken` 的真实读法一致。
    ///
    /// ## 为什么这条测试值得存在
    ///
    /// `proxyToken` 原本是 `let`（只在 `init` 读一次），那时「需重启 App 生效」
    /// 是**真话**。把它改成 computed property 之后，那句文案就变成了假话 ——
    /// 用户会为一个根本不需要的重启而重启，然后怀疑令牌没存进去。
    ///
    /// 这类不一致编译器不会报、UI 测试也抓不到（它只是文字），
    /// 而且它偏偏出现在**修好 bug 之后**：改了实现却忘了改文案。
    /// 所以这里直接读源码，把两者的口径焊在一起。
    ///
    /// ## 为什么必须只扫「代理令牌」这一段
    ///
    /// 第一版扫的是整个文件，结果报红 —— 但那是**误报**：
    /// 直连密钥区块（`debugKeySection`）里「保存后需重启才会重新解析接入方式」
    /// 是**真话**，因为 `EndpointConfiguration.resolve()` 确实在启动时解析模式。
    /// 把不同功能的口径混在一个断言里，只会逼着后来人去改正确的文案。
    /// 断言的作用域必须和它描述的行为一样窄。
    func testBetaTokenCopyMatchesTokenReadBehaviour() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // 仓库根
        let settings = try String(
            contentsOf: root.appendingPathComponent("Presentation/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let aiService = try String(
            contentsOf: root.appendingPathComponent("Services/AIService.swift"),
            encoding: .utf8
        )

        // 前提校验：先确认 `proxyToken` 确实是每次重读，否则下面的断言没有意义。
        // 若哪天有人把它改回缓存，这条会先报红，提示"文案该改回去了"。
        let isComputed = aiService.contains("private var proxyToken: String?")
            || aiService.contains("var proxyToken: String? {")
        XCTAssertTrue(
            isComputed,
            "proxyToken 不再是 computed property。若改回 init 缓存，设置页文案必须恢复成「需重启生效」。"
        )

        // 只取代理令牌这一段的源码。
        let section = try XCTUnwrap(
            Self.block(named: "betaProxyTokenSection", in: settings),
            "找不到 betaProxyTokenSection —— 若已改名，请同步更新本测试"
        )

        // 只看**用户能看到的字符串字面量**，跳过注释。
        //
        // 这个断言前后错了三次，每次都是同一个毛病：拿"文件里有没有某个词"
        // 当代理指标，而那个词的分布范围比它想描述的行为宽得多。
        //   ① 扫全文件 → 命中直连密钥区块里**正确**的「重启生效」；
        //   ② 只看区块 → 命中我自己写的解释性注释；
        //   ③ 用 `contains("重启")` → 命中正确的「无需重启」。
        // 结论：断言必须落在**同一语义层**上。这里要管的是用户读到的文字，
        // 那就只取 `Text("...")` 里的字面量，注释和标识符都不该进来。
        let visibleCopy = Self.stringLiterals(in: section)

        // 前提校验：确认真的取到了文案，否则下面的"没发现问题"毫无意义。
        XCTAssertFalse(
            visibleCopy.isEmpty,
            "没有从代理令牌区块里提取到任何文案 —— 提取逻辑失效时不该静默通过"
        )

        // 「无需重启」是正确表述，先剔除再判断有没有叫人去重启。
        let withoutNegations = visibleCopy
            .replacingOccurrences(of: "无需重启", with: "")
            .replacingOccurrences(of: "不用重启", with: "")

        XCTAssertFalse(
            withoutNegations.contains("重启"),
            "代理令牌区块仍在要求用户重启，但 proxyToken 已是每次请求重读 —— 这句文案现在是假话"
        )
    }

    /// 取出源码里所有 `"..."` 形式的字符串字面量，拼成一段。
    ///
    /// 只服务于本文件的源码级断言，不需要处理转义与插值 ——
    /// 真要处理那些，就该换个更正经的解析方式，而不是加正则。
    private static func stringLiterals(in source: String) -> String {
        var literals: [String] = []
        var current: String?
        var iterator = source.makeIterator()
        var pending: Character?

        while let ch = pending ?? iterator.next() {
            pending = nil
            if ch == "\"" {
                if let open = current {
                    literals.append(open)
                    current = nil
                } else {
                    current = ""
                }
                continue
            }
            if current != nil { current?.append(ch) }
        }
        return literals.joined(separator: "\n")
    }

    /// 从源码里截出 `private var <name>` 到下一个 `// MARK:` 之间的内容。
    private static func block(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "private var \(name)") else { return nil }
        let rest = source[start.lowerBound...]
        if let end = rest.range(of: "// MARK:", range: rest.index(start.lowerBound, offsetBy: 1)..<rest.endIndex) {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }
}
