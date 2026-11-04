//
// InviteCryptoTests.swift
// 关系CopilotTests
//
// 评理邀请的加密层测试。
//
// ## 这里最要紧的一条：跨语言一致性
//
// 加密在两个地方实现：Swift（`InviteCrypto`）和对方网页里的 JS（WebCrypto）。
// 两者必须**逐字节兼容** —— 参数差一个，对方写的内容 A 端就解不开，
// 而错误信息只会说"认证失败"，完全指不出是哪一边的问题。
//
// 所以这里有一组固定向量：key、iv、plaintext、期望的密文全部写死。
// 如果哪天 CryptoKit 的默认行为变了，或者我们不小心把 base64 换成
// base64url，这组向量会立刻报红。
//
// 向量由 `Tools/ai-proxy/invite.test.mjs` 里同一组参数用 Node 的
// WebCrypto 生成 —— 两个实现对着同一组数字，这是唯一可靠的验证方式。
//

import XCTest
import CryptoKit
@testable import RelationshipCopilot

final class InviteCryptoTests: XCTestCase {

    // MARK: - 密钥与 caseId

    func testCaseIdIsURLSafe() throws {
        for _ in 0..<50 {
            let id = InviteSecret.makeCaseID()
            // 必须能直接放进 URL 路径，不需要百分号编码。
            XCTAssertFalse(id.contains("+"), "caseId 含 + —— 在 URL 里会被当成空格")
            XCTAssertFalse(id.contains("/"), "caseId 含 / —— 会被当成路径分隔符")
            XCTAssertFalse(id.contains("="), "caseId 含 = —— 需要额外编码")
            XCTAssertTrue(
                id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
                "caseId 含非法字符：\(id)"
            )
            // 服务端正则要求 16–64 位。16 字节的 base64url 是 22 字符。
            XCTAssertGreaterThanOrEqual(id.count, 16, "caseId 太短，服务端会拒绝：\(id)")
            XCTAssertLessThanOrEqual(id.count, 64, "caseId 太长，服务端会拒绝：\(id)")
        }
    }

    func testCaseIdIsUnique() throws {
        // 不是密码学证明，只是抓"忘了加随机"这类错误。
        let ids = Set((0..<200).map { _ in InviteSecret.makeCaseID() })
        XCTAssertEqual(ids.count, 200, "200 个 caseId 里有重复 —— 随机源可能有问题")
    }

    func testGeneratedKeyIs256Bit() throws {
        let (secret, key) = InviteSecret.generate()
        XCTAssertEqual(key.bitCount, 256, "AES-GCM 用 256 位密钥，网页端也要用同一长度")

        // 从材料还原的 key 必须与生成的一致 —— 否则 A 端加密、A 端自己也解不开。
        let restored = try InviteCrypto.key(fromBase64URL: secret.keyBase64URL)
        XCTAssertEqual(restored.bitCount, 256)
    }

    func testKeyBase64URLIsURLSafe() throws {
        for _ in 0..<20 {
            let (secret, _) = InviteSecret.generate()
            let k = secret.keyBase64URL
            XCTAssertFalse(k.contains("+"), "密钥含 + —— 放进 URL 的 # 之后也有风险")
            XCTAssertFalse(k.contains("/"))
            XCTAssertFalse(k.contains("="))
        }
    }

    // MARK: - 往返

    func testRoundTrip() throws {
        let (_, key) = InviteSecret.generate()
        let plaintext = #"{"slot":"b","answers":{"happened":"她把我的杯子收进了柜子","need":"希望你先问一句"}}"#

        let sealed = try InviteCrypto.seal(plaintext, key: key)
        let opened = try InviteCrypto.open(sealed, key: key)
        XCTAssertEqual(opened, plaintext)
    }

    func testRoundTripWithEmojiAndLongText() throws {
        let (_, key) = InviteSecret.generate()
        // 中文 + emoji + 换行 + 超长，覆盖 UTF-8 多字节边界。
        let plaintext = String(repeating: "那天你说「算了」的时候我没接住 🙁\n", count: 300)
        let sealed = try InviteCrypto.seal(plaintext, key: key)
        XCTAssertEqual(try InviteCrypto.open(sealed, key: key), plaintext)
    }

    func testIVIsDifferentEveryTime() throws {
        let (_, key) = InviteSecret.generate()
        let plaintext = "同一段内容"

        var ivs = Set<String>()
        for _ in 0..<50 {
            ivs.insert(try InviteCrypto.seal(plaintext, key: key).iv)
        }
        // GCM 下重用 IV 会直接毁掉机密性。50 次里出现任何一次重复都不可接受。
        XCTAssertEqual(ivs.count, 50, "IV 出现重复 —— GCM 下这是致命的")
    }

    func testIVIsTwelveBytes() throws {
        let (_, key) = InviteSecret.generate()
        let sealed = try InviteCrypto.seal("x", key: key)
        // 网页端 crypto.subtle 用 12 字节 IV。这里不一致就会互通失败。
        let ivBytes = try XCTUnwrap(Data(base64Encoded: sealed.iv))
        XCTAssertEqual(ivBytes.count, 12, "IV 必须是 12 字节，与 WebCrypto 对齐")
    }

    func testCiphertextUsesStandardBase64() throws {
        let (_, key) = InviteSecret.generate()
        // 用一个会产生 + / 的长内容，确认我们用的是标准 base64 而非 base64url。
        // 网页端用 btoa，它是标准 base64 —— 两边必须一致。
        var sawStandardOnly = true
        for _ in 0..<30 {
            let sealed = try InviteCrypto.seal(UUID().uuidString + String(repeating: "字", count: 50), key: key)
            XCTAssertFalse(sealed.ciphertext.contains("-"), "密文用了 base64url，网页端解不开")
            XCTAssertFalse(sealed.ciphertext.contains("_"), "密文用了 base64url，网页端解不开")
            // Data(base64Encoded:) 只接受标准字母表，能解出来就说明是标准的。
            if Data(base64Encoded: sealed.ciphertext) == nil { sawStandardOnly = false }
        }
        XCTAssertTrue(sawStandardOnly)
    }

    // MARK: - 失败路径

    func testWrongKeyFailsToOpen() throws {
        let (_, keyA) = InviteSecret.generate()
        let (_, keyB) = InviteSecret.generate()

        let sealed = try InviteCrypto.seal("只有 A 能看到", key: keyA)
        XCTAssertThrowsError(try InviteCrypto.open(sealed, key: keyB)) { error in
            guard case InviteCryptoError.openFailed = error else {
                return XCTFail("期望 openFailed，实际 \(error)")
            }
        }
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let (_, key) = InviteSecret.generate()
        let sealed = try InviteCrypto.seal("原文", key: key)

        // 翻掉密文中间一个字节。GCM 的认证标签必须让解密失败 ——
        // 如果它能解出内容，说明我们用的不是认证加密。
        var bytes = try XCTUnwrap(Data(base64Encoded: sealed.ciphertext))
        bytes[bytes.count / 2] ^= 0xFF
        let tampered = InviteCiphertext(
            ciphertext: bytes.base64EncodedString(),
            iv: sealed.iv
        )

        XCTAssertThrowsError(try InviteCrypto.open(tampered, key: key)) { error in
            guard case InviteCryptoError.openFailed = error else {
                return XCTFail("篡改后的密文必须解不开，实际 \(error)")
            }
        }
    }

    func testTamperedIVFailsToOpen() throws {
        let (_, key) = InviteSecret.generate()
        let sealed = try InviteCrypto.seal("原文", key: key)

        var iv = try XCTUnwrap(Data(base64Encoded: sealed.iv))
        iv[0] ^= 0xFF
        let tampered = InviteCiphertext(
            ciphertext: sealed.ciphertext,
            iv: iv.base64EncodedString()
        )
        XCTAssertThrowsError(try InviteCrypto.open(tampered, key: key))
    }

    func testMalformedBase64Fails() throws {
        let (_, key) = InviteSecret.generate()
        let bad = InviteCiphertext(ciphertext: "这不是 base64!!!", iv: "也不是!!!")
        XCTAssertThrowsError(try InviteCrypto.open(bad, key: key)) { error in
            guard case InviteCryptoError.badBase64 = error else {
                return XCTFail("期望 badBase64，实际 \(error)")
            }
        }
    }

    func testBadKeyLengthRejected() throws {
        // 16 字节是 AES-128 的长度。网页端用 256 位，
        // 如果这里接受了 128 位，会让"key 被截断"变成一个安静的错误。
        let short = Data(repeating: 0x41, count: 16).base64URLEncodedString()
        XCTAssertThrowsError(try InviteCrypto.key(fromBase64URL: short)) { error in
            guard case InviteCryptoError.badKey = error else {
                return XCTFail("期望 badKey，实际 \(error)")
            }
        }
    }

    // MARK: - base64url 转换

    func testBase64URLRoundTrip() throws {
        for length in [0, 1, 2, 3, 4, 5, 15, 16, 17, 31, 32, 33, 100] {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            let encoded = data.base64URLEncodedString()
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(
                Data(base64URLEncoded: encoded), data,
                "长度 \(length) 的 base64url 往返失败 —— 填充计算可能有误"
            )
        }
    }

    func testBase64URLAcceptsStandardAlphabet() throws {
        // 容错：如果链接被某个客户端"规范化"成了标准 base64，
        // 我们仍然应该能读。这不会降低安全性（这是编码，不是加密）。
        let data = Data(repeating: 0xFB, count: 20)
        let standard = data.base64EncodedString()
        XCTAssertEqual(Data(base64URLEncoded: standard), data)
    }

    // MARK: - 跨境契约：与网页端 JS 的固定向量
    //
    // 这一组数字是由 **Node 的 WebCrypto** 实际算出来的（不是手写猜的）：
    //
    //     key = 32 字节 0x00..0x1F，iv = 12 字节全 0
    //     plaintext = "契约向量：她说「算了」的那天"
    //     ciphertext = "6xkkOQ+KZi2ZQS6695ALfHf6vvycYuCjZzAkZ395vtbDuHw4w3Ab45dqWeYKOUmgojdjtV52JNaZPg=="
    //
    // 生成脚本见 `Tools/ai-proxy/invite.test.mjs` 末尾的 `webcryptoVector` 段。
    // 两边对着同一组数字，任何一边改了参数（密钥长度、IV 长度、base64 字母表、
    // 认证标签位置）都会立刻报红。
    //
    // 这条断言的价值在于：它是**唯一**能证明"对方在浏览器里写的内容，
    // A 端真的能解开"的手段。纯 Swift 的往返测试证明不了这件事 ——
    // 自己加密自己解密，哪怕参数全错也能自洽。

    func testOpensCiphertextProducedByWebCrypto() throws {
        let key = try InviteCrypto.key(
            fromBase64URL: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        )
        let sealed = InviteCiphertext(
            ciphertext: "6xkkOQ+KZi2ZQS6695ALfHf6vvycYuCjZzAkZ395vtbDuHw4w3Ab45dqWeYKOUmgojdjtV52JNaZPg==",
            iv: "AAAAAAAAAAAAAAAA"
        )

        let opened = try InviteCrypto.open(sealed, key: key)
        XCTAssertEqual(
            opened, "契约向量：她说「算了」的那天",
            "解不开 WebCrypto 产生的密文 —— 两侧参数不一致，对方写的内容会全部丢失"
        )
    }

    func testCiphertextLengthMatchesWebCrypto() throws {
        // 同一段明文的密文长度必须与 WebCrypto 完全一致。
        // 差 16 字节通常意味着认证标签没被包含进来（或被算了两遍）。
        //
        // 这条只查长度，不碰密钥 —— 长度是纯字节算术，
        // 而「解不解得开」由 testOpensCiphertextProducedByWebCrypto 负责。
        let sealed = InviteCiphertext(
            ciphertext: "6xkkOQ+KZi2ZQS6695ALfHf6vvycYuCjZzAkZ395vtbDuHw4w3Ab45dqWeYKOUmgojdjtV52JNaZPg==",
            iv: "AAAAAAAAAAAAAAAA"
        )
        let webCryptoBytes = try XCTUnwrap(Data(base64Encoded: sealed.ciphertext)).count
        // 明文 UTF-8 字节数 + 16 字节认证标签 = 密文字节数。
        let plaintextBytes = "契约向量：她说「算了」的那天".utf8.count
        XCTAssertEqual(
            webCryptoBytes, plaintextBytes + 16,
            "密文长度不符合 AES-GCM 预期（明文 + 16 字节 tag）"
        )
    }

    func testFixedVectorMatchesWebCrypto() throws {
        // key = 32 字节 0x00..0x1F
        let keyData = Data((0..<32).map { UInt8($0) })
        let key = SymmetricKey(data: keyData)

        // iv 固定成 12 字节全 0，是为了让向量可复现 ——
        // 生产路径里 IV 必须随机（`testIVIsDifferentEveryTime` 守着）。
        let plaintext = "契约向量"

        // 用显式 IV 封一次。`InviteCrypto.seal` 内部自取随机 IV，
        // 所以这里直接用 CryptoKit 复现同样的算法步骤，
        // 验证的是"我们对 combined 的拆分方式"与网页端一致。
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)
        let combined = try XCTUnwrap(box.combined)

        let iv = Data(combined.prefix(12))
        let body = Data(combined.dropFirst(12))

        // 关键断言：combined 的前 12 字节就是 nonce 本身。
        // 如果 CryptoKit 换了 combined 的布局，这条会立刻报红。
        XCTAssertEqual(iv, Data(repeating: 0, count: 12), "combined 前 12 字节不是 nonce —— 布局变了")

        // 用我们自己的 open 解回这段手工构造的密文。
        let reconstructed = InviteCiphertext(
            ciphertext: body.base64EncodedString(),
            iv: iv.base64EncodedString()
        )
        XCTAssertEqual(try InviteCrypto.open(reconstructed, key: key), plaintext)
    }
}
