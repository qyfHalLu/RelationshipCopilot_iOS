//
// InviteCrypto.swift
// 关系Copilot
//
// 评理邀请的**客户端**加密。
//
// ## 为什么加密必须在这一层，而不是服务端
//
// 邀请链接会经过微信、短信、剪贴板。如果证词以明文上送，那么：
//   · 服务端（以及它的日志、备份、运维人员）能读到最私密的内容；
//   · 任何一次服务端配置失误都会让这些内容变成可被检索的数据集。
//
// 所以密钥只在两端：A 端生成、随 URL 的 `#` 之后传递、B 端在浏览器里取用。
// 服务端拿到的永远是密文。这个文件是 A 端那一侧的加密实现，
// 与对方网页里的 WebCrypto 代码必须**算法一致**，否则对方写的东西 A 端解不开。
//
// ## 算法选择的约束
//
// 对方的填写页是浏览器里的 `crypto.subtle`，它支持的 AEAD 只有 AES-GCM
// 和 ChaCha20-Poly1305（后者并非所有浏览器都开）。所以只能选 AES-GCM。
// 参数必须与网页端逐字对齐：
//   · 算法 AES-GCM
//   · 密钥 32 字节（AES-256）
//   · IV 12 字节（GCM 的标准长度，crypto.subtle 默认 12）
//   · 认证标签 128 位（GCM 默认）
// 任何一项不一致，对方写入的内容 A 端会解出乱码或直接报认证失败。
//

import Foundation
import CryptoKit

/// 一次邀请的密钥材料。
///
/// `caseId` 与 `key` 分开是有意的：`caseId` 是**公开**的（走 URL 路径，
/// 服务端用它当 KV 键），`key` 是**秘密**的（走 URL 的 `#` 之后，
/// 永远不进入 HTTP 请求，也不进日志）。
struct InviteSecret: Equatable {
    let caseId: String
    /// 32 字节的对称密钥，base64url（无填充）。
    let keyBase64URL: String

    /// 32 字节随机密钥。
    static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// 16 字节随机 caseId，base64url。
    ///
    /// 16 字节 = 128 位随机。即便有人枚举，也不可能撞上一个正在等待的案卷；
    /// 而 KV 里的键靠 TTL 7 天自然消失，不需要"猜不到"以外的保护。
    static func makeCaseID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// 生成一套新的邀请材料。
    static func generate() -> (secret: InviteSecret, key: SymmetricKey) {
        let key = makeKey()
        let raw = key.withUnsafeBytes { Data($0) }
        return (
            InviteSecret(caseId: makeCaseID(), keyBase64URL: raw.base64URLEncodedString()),
            key
        )
    }
}

// MARK: - 密文

/// 与网页端 `{ ciphertext, iv }` 一一对应的结构。
///
/// 两个字段都是 base64（标准字母表，带 `=` 填充）——
/// 网页端用的是 `btoa`，它是标准 base64，不是 base64url。
/// 这里如果图省事用 base64url，AES-GCM 解密会因为密钥字节不同而失败，
/// 而报错只会说"认证失败"，排查起来会绕很久。
struct InviteCiphertext: Codable, Equatable {
    let ciphertext: String
    let iv: String
}

enum InviteCryptoError: LocalizedError {
    case badKey
    case badBase64
    case sealFailed(String)
    case openFailed

    var errorDescription: String? {
        switch self {
        case .badKey:
            return "邀请密钥无效，这个链接可能被截断了。"
        case .badBase64:
            return "内容格式不对，无法解密。"
        case .sealFailed(let reason):
            return "加密失败：\(reason)"
        case .openFailed:
            return "无法解密对方写的内容 —— 链接密钥不匹配，或内容已损坏。"
        }
    }
}

enum InviteCrypto {

    /// 加密。IV 每次随机，**绝不复用** —— GCM 下重复 IV 会直接毁掉机密性。
    static func seal(_ plaintext: String, key: SymmetricKey) throws -> InviteCiphertext {
        guard let data = plaintext.data(using: .utf8) else {
            throw InviteCryptoError.sealFailed("内容无法编码")
        }
        do {
            let box = try AES.GCM.seal(data, using: key)
            guard let combined = box.combined else {
                throw InviteCryptoError.sealFailed("无法取出密文")
            }
            // `combined` 是 nonce(12) + ciphertext + tag(16)。
            // 拆开分别传，因为对方网页端就是这么组织的 —— 契约要逐字对齐。
            let nonceSize = 12
            guard combined.count > nonceSize else {
                throw InviteCryptoError.sealFailed("密文长度异常")
            }
            let iv = combined.prefix(nonceSize)
            let body = combined.dropFirst(nonceSize)
            return InviteCiphertext(
                ciphertext: Data(body).base64EncodedString(),
                iv: Data(iv).base64EncodedString()
            )
        } catch let error as InviteCryptoError {
            throw error
        } catch {
            throw InviteCryptoError.sealFailed(error.localizedDescription)
        }
    }

    /// 解密。
    ///
    /// 把 `iv` 与 `ciphertext` 重新拼成 `combined` 再交给 CryptoKit。
    /// 解密失败只有两种可能：密钥不对，或内容被动过 —— AES-GCM 的认证标签
    /// 会同时覆盖这两种情况，所以错误信息里不该假装能区分它们。
    static func open(_ sealed: InviteCiphertext, key: SymmetricKey) throws -> String {
        guard let ivData = Data(base64Encoded: sealed.iv),
              let bodyData = Data(base64Encoded: sealed.ciphertext) else {
            throw InviteCryptoError.badBase64
        }
        var combined = Data(ivData)
        combined.append(bodyData)

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw InviteCryptoError.openFailed
            }
            return text
        } catch let error as InviteCryptoError {
            throw error
        } catch {
            throw InviteCryptoError.openFailed
        }
    }

    /// 从 base64url 还原密钥。
    static func key(fromBase64URL string: String) throws -> SymmetricKey {
        guard let data = Data(base64URLEncoded: string), data.count == 32 else {
            throw InviteCryptoError.badKey
        }
        return SymmetricKey(data: data)
    }
}

// MARK: - base64url

//
// base64url 与标准 base64 的区别只有两个字符（`+`→`-`、`/`→`_`）和去掉填充。
// 必须做这个转换：caseId 与 key 都要放进 URL，标准 base64 的 `+` 和 `/`
// 在 URL 里需要百分号编码，而各平台对 URL 里 `+` 的处理并不一致
// （有的当空格），会制造"链接在 A 那能打开、在 B 那不行"的偶发故障。
//

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 补齐填充：Data(base64Encoded:) 要求长度是 4 的倍数。
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: s) else { return nil }
        self = data
    }
}
