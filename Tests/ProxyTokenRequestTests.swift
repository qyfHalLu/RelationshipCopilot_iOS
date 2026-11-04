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
}
