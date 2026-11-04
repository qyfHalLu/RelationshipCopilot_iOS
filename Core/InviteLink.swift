//
// InviteLink.swift
// 关系Copilot
//
// 远程邀请的链接构造。**纯函数，无 I/O**，可直接单测。
//
// ## 这个文件只有一件事，但那一件事是整套方案的地基
//
// 密钥必须放在 URL 的 `#` 之后。
//
//   ✅ https://proxy.example.com/v1/invite/{caseId}/page#{key}
//   ❌ https://proxy.example.com/v1/invite/{caseId}/page?k={key}
//
// 差别不是风格问题：
//   · `#` 之后的部分**不会发到服务器** —— 不进 HTTP 请求行、不进访问日志、
//     不进 Referer、不进 CDN 缓存键。服务端从结构上就拿不到密钥。
//   · query string 会进上面所有这些地方。
//
// 所以构造链接这件事不能散落在视图里随手拼字符串 ——
// 一旦有人图方便改成 query，服务端就"能"读到证词了，
// 而所有测试（它们用的是正确的链接）都还是绿的。
//

import Foundation

/// 一次远程邀请的链接材料。
struct InviteLink: Equatable {

    /// 服务端白板上的键。公开。
    let caseId: String

    /// 对称密钥，base64url。**秘密**，只出现在 fragment 里。
    let keyBase64URL: String

    /// 邀请链接的路径部分，不含 fragment。
    ///
    /// 单独暴露是为了让测试能断言"路径里不含密钥"这个反面条件 ——
    /// 只检查完整链接里"有 #key"是不够的，那无法排除"路径里也放了一份"。
    static let pagePathPrefix = "v1/invite"

    init(caseId: String, keyBase64URL: String) {
        self.caseId = caseId
        self.keyBase64URL = keyBase64URL
    }

    /// 从客户端生成的密钥材料构造。
    init(secret: InviteSecret) {
        self.caseId = secret.caseId
        self.keyBase64URL = secret.keyBase64URL
    }

    /// 对方要打开的完整链接。
    ///
    /// - Parameter proxyBaseURL: Worker 根地址（与 AI 代理同一个）。
    /// - Returns: 失败时返回 nil —— 包括"baseURL 里已经带了 query/fragment"
    ///   这种会让密钥暴露或被覆盖的病态输入。
    func url(proxyBaseURL: URL) -> URL? {
        // baseURL 自带 query 或 fragment 时直接拒绝：
        //   · 自带 fragment → 我们这个 `#key` 会覆盖它，或反过来把它顶掉；
        //   · 自带 query     → 拼出来的路径会变成 `...?x=1/v1/invite/...`。
        // 两种都说明配置有问题，静默拼一个坏链接比明确失败更糟。
        guard proxyBaseURL.query == nil, proxyBaseURL.fragment == nil else { return nil }

        var components = URLComponents()
        components.scheme = proxyBaseURL.scheme
        components.host = proxyBaseURL.host
        components.port = proxyBaseURL.port
        // 保留 baseURL 自带的路径前缀（Worker 可能挂在 /api 之类的子路径下）。
        let basePath = proxyBaseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = [basePath, Self.pagePathPrefix, caseId, "page"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/" + path

        // 关键：用 fragment 而不是 query。
        components.fragment = keyBase64URL

        return components.url
    }

    /// 分享时附带的说明文字。
    ///
    /// 这段话会和链接一起进聊天框，所以它必须**不假定关系、不假定性别**，
    /// 也不能暗示"你被指控了"——收到链接的人在这件事里同样有一份。
    static func shareMessage(relationshipLabel: String?) -> String {
        let who = relationshipLabel.map { "关于我们之间的一件事（\($0)）" } ?? "关于我们之间的一件事"
        return "\(who)，我想用这个方式各自写一遍，然后一起看看卡在哪。链接点开就能写，不用装 App。"
    }
}
