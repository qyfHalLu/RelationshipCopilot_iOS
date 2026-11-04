//
// InviteService.swift
// 关系Copilot
//
// 评理邀请的网络层。
//
// ## 它只做两件事
//
//   1. 取回   GET /v1/invite/:caseId → { slots, awaiting, testimonies }
//
// 写入由**对方**完成（在网页里），A 端不写 —— A 自己的证词本来就在本机数据库里，
// 没有任何理由再上送一份密文到服务器。上送一份就多一份暴露面，
// 而它换来的唯一好处是"能从服务器恢复自己写的内容"，这不是需求。
//
// 领位（claim）也不由 A 端调用：A 端是发起方，它不占位置。
// 两个位置都留给"被邀请的人"和"第一个人自己"——
// 这个不对称是刻意的，见 `invite.js` 里 `handleClaim` 的注释。
//
// ## 这个层不碰加密
//
// 密文的加解密在 `InviteCrypto`。这一层的入参出参都是 `InviteCiphertext`，
// 它不知道里面是什么，也不需要知道。分层不是为了好看 ——
// 它让"服务端读不懂内容"这件事在客户端也表达得出来：
// 网络层根本没有明文的类型。
//
// ## 复用 AI 代理的地址与令牌
//
// 邀请和 AI 走同一个 Worker。再配一套地址与令牌，只会让"其中一个没配"
// 变成新的故障模式，而这两个功能在用户眼里是同一件事的一部分。
//

import Foundation

/// 邀请专用的错误。
///
/// 刻意不复用 `AppError`：那些文案是围绕"AI 分析"写的
/// （「AI 服务尚未配置」「正在分析中，请稍候」）。
/// 在邀请屏上出现「AI 服务尚未配置」会让用户以为 AI 坏了，
/// 而他此刻唯一关心的是"我发给对方那条链接到底行不行"。
enum InviteServiceError: LocalizedError, Equatable {
    case notConfigured
    case expired

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "这台设备还没连上服务端，暂时没法用链接邀请。可以先用「同一台手机」的方式。"
        case .expired:
            return "这个邀请已经失效了，可能已过期。"
        }
    }
}

/// 邀请的服务端状态。
struct InviteStatus: Equatable {
    struct Slots: Equatable {
        let a: Bool
        let b: Bool
    }

    /// 哪些位置已经被**领取**。`true` 只代表有人打开了链接，
    /// 不代表已经写完 —— 这个区别决定了界面该说"对方还没打开"还是"等对方写完"。
    let slots: Slots
    /// 还差谁写。空数组 = 两份都写完了。
    let awaiting: [String]
    /// 已写好的密文。键是 `"a"` / `"b"`。
    let testimonies: [String: InviteCiphertext]

    /// 对方那份是否已经写好。
    var counterpartHasWritten: Bool { testimonies["b"] != nil }

    /// 对方是否至少打开过链接。
    ///
    /// 值得单独区分：用户看到"还没打开"会想去催一下或换个方式发；
    /// 看到"已打开但没写"则知道对方正在写、或暂时不想写。
    /// 把这两种合成一个"等待中"，等于把有用的信息丢掉。
    var counterpartOpenedLink: Bool { slots.b }
}

/// `@MainActor` 而不是 `Sendable`：实现里要用到 `SecureStoring`
/// （非 Sendable 的 Keychain 封装）。这个协议只被 UI 层调用，
/// 没有跨 actor 传递的需求 —— 标成 Sendable 只会制造与实现不一致的假契约。
@MainActor
protocol InviteServicing {
    func fetchStatus(caseId: String) async throws -> InviteStatus
}

/// 与 `AIService` 一致：`@MainActor` 标记。
///
/// 不标的话会出两个 Swift 6 警告：`SecureStoring` 不是 `Sendable`，
/// 而 `AIService.proxyTokenHeader` 是 main actor 隔离的。
/// 标在这里不损失什么 —— 这个类型只做一次网络往返，
/// 真正的并发压力在 `URLSession`，不在这一层。
@MainActor
struct InviteService: InviteServicing {
    private let mode: AIEndpointMode
    private let keychain: SecureStoring
    private let session: URLSession

    /// 显式指定的代理根地址。
    ///
    /// ## 为什么需要这个口子
    ///
    /// 早先这里只有 `mode`，由 `EndpointConfiguration.resolve` 现场解析。
    /// 结果是：调用方（`DisputeFlowView`）手里已经有解析好的 `proxyBaseURL`
    /// （它还支持 UI 测试注入），而这一层又独立解析了一次 ——
    /// 两次解析在"Info.plist 空但测试注入了地址"时会得出不同答案，
    /// 于是**链接用的是 A 地址、请求打向 B 地址**，或者干脆两边都没有。
    ///
    /// 症状很隐蔽：链接卡片正常显示，一点刷新就弹出一句
    /// 「AI 服务尚未配置」—— 用户完全不知道 AI 跟邀请有什么关系。
    ///
    /// 现在允许调用方把地址传进来，只解析一次。
    private let explicitBaseURL: URL?

    /// 与 `AIService.proxyTokenHeader` 必须一致，否则服务端只认一边。
    static var proxyTokenHeader: String { AIService.proxyTokenHeader }

    init(
        mode: AIEndpointMode? = nil,
        baseURL: URL? = nil,
        keychain: SecureStoring = SecureStorageService.shared,
        session: URLSession = .shared
    ) {
        self.mode = mode ?? EndpointConfiguration.resolve(keychain: keychain)
        self.explicitBaseURL = baseURL
        self.keychain = keychain
        self.session = session
    }

    private var proxyToken: String? {
        try? keychain.retrieve(key: EndpointConfiguration.proxyTokenKeychainAccount)
    }

    /// 代理根地址。邀请链接要用它与 AI 走同一个 Worker ——
    /// 再配一个独立地址只会多出一种"其中一个没配"的故障模式。
    ///
    /// 直连模式下返回 nil：这时候没有 Worker 可以托管邀请白板，
    /// 界面应当把远程模式整个藏起来，而不是生成一个打不开的链接。
    var proxyBaseURL: URL? {
        if let explicitBaseURL { return explicitBaseURL }
        if case .proxy(let baseURL) = mode { return baseURL }
        return nil
    }

    /// 远程模式是否可用。UI 据此决定是否把"让对方在自己手机上写"作为可选项。
    var isRemoteAvailable: Bool { proxyBaseURL != nil }

    func fetchStatus(caseId: String) async throws -> InviteStatus {
        guard let baseURL = proxyBaseURL else {
            // 直连模式没有这台 Worker。不能用直连地址去拼邀请路径 ——
            // 那会把请求打到模型厂商的服务器上。
            //
            // 这里用专门的文案而不是 `.aiNotConfigured`：
            // 在邀请屏上显示「AI 服务尚未配置」会让用户以为 AI 出了问题，
            // 而他此刻关心的是"我发给对方的那条链接"。
            throw InviteServiceError.notConfigured
        }

        var request = URLRequest(url: baseURL.appending(path: "v1/invite/\(caseId)"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        if let token = proxyToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: Self.proxyTokenHeader)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverError(-1)
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw AppError.unauthorized
        case 404, 410:
            // 在这个协议里 404 意味着"过期或不存在"，不是"路径写错了"。
            // 界面要据此提示重新生成链接，而不是报一个技术错误。
            throw InviteServiceError.expired
        case 429:
            throw AppError.quotaExceeded
        case 503:
            throw InviteServiceError.notConfigured
        default:
            throw AppError.serverError(http.statusCode)
        }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AppError.malformedAIResponse("邀请状态无法解析")
        }

        return InviteStatus(
            slots: .init(a: payload.slots.a, b: payload.slots.b),
            awaiting: payload.awaiting,
            testimonies: payload.testimonies
        )
    }

    private struct Response: Decodable {
        struct Slots: Decodable {
            let a: Bool
            let b: Bool
        }
        let slots: Slots
        let awaiting: [String]
        let testimonies: [String: InviteCiphertext]
    }
}
