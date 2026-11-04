# 关系副驾 · RelationshipCopilot

记录对话 → 看清关系里的模式 → 给下一步可执行的动作。

> 这个 README 描述的是**当前代码的真实行为**，不是路线图。仓库里两份历史上的
> 「开发完成报告 / 开发进度报告」写于 2026-03-17（开发第一天），描述的是计划，已不代表现状。

## 功能

| 模块 | 能力 | 状态 |
|---|---|---|
| 关系档案 | 人物增删改，关系类型（伴侣/配偶/家人/朋友/同事/其他，选「其他」可自定义名称），头像（12 色可选 + 任意取色 + 上传照片），备注 | 可用 |
| 记录对话 | 边录边转写（AVAudioEngine + 语音识别），锁屏可继续，结束后调用 AI 分析并落库 | 可用，需配置 AI 服务 |
| 分析报告 | 历史记录、本月统计、单条详情（评分/优点/改进/建议/情绪走势/沟通质量） | 可用 |
| 承诺追踪 | 每日打卡（做到/部分/没做到）、履约率、连续天数、到期结算、到期提醒 | 可用 |
| 快速工具 | 吵架复盘 / 话术急救 / 道歉生成 / 关系体检，真实调用模型 | 可用，需配置 AI 服务 |
| 说清一件事 | 双方各自写 4 个问题的证词，互不可见，AI 同时读两份后给责任比与建议 | 可用，需配置 AI 服务 |
| 跨设备邀请 | 生成一次性链接，对方**在自己手机上**用浏览器填写；支持微信 / 短信 / 任意聊天工具送达 | 可用，需部署邀请服务 |
| 小组件 | 桌面显示当前关系健康度，数据由主 App 写入 | 可用 |
| 账号 | 手机号 + 验证码（当前无后端，仅 DEBUG 演示登录） | 演示 |
| 数据管理 | 导出全部数据为 JSON、永久删除全部本地数据 | 可用 |

## 技术栈

- Swift 5.9 / SwiftUI / SwiftData（iOS 17.0+，仅 iPhone）
- XcodeGen 管理工程（`project.yml` 是唯一工程事实来源，`.xcodeproj` 不入库）
- 无第三方依赖

## 目录结构

```
App/            应用入口、Info.plist、PrivacyInfo.xcprivacy、Assets
Core/           纯逻辑层（无 UI / 无数据库依赖，可单测）
                RelationshipHealth / FulfillmentStats / AIResponseParser
                QuotaPolicy / Validation / RelationshipType / AppError / AppLog
                DisputeTestimony / DisputeCaseState / DisputeEvaluation（说清一件事）
                InviteLink / InvitePayload / InviteCrypto（跨设备邀请的链接与载荷）
Data/Models/    SwiftData 模型（User / Profile / Promise / FulfillmentRecord / RecordingSession / DisputeCase）
Services/       AIService / RecordingService / NotificationService / AuthenticationService
                InviteService / WidgetDataStore / DataMaintenance
Presentation/   Theme + Views（Home / Profiles / Promises / Recording / Analysis / QuickTools / Dispute / Settings）
Tests/          XCTest 单元测试
UITests/        XCUITest 截图核验（逐屏留图 + 布局断言）
Tools/logic-check/  不依赖 XCTest 的逻辑冒烟脚本（可在无模拟器环境运行）
Tools/ai-proxy/     Cloudflare Worker：AI 代理 + 邀请链接服务
```

## 运行

```bash
brew install xcodegen
xcodegen generate
open RelationshipCopilot.xcodeproj
```

命令行构建与测试：

```bash
# 构建
xcodebuild -project RelationshipCopilot.xcodeproj -scheme RelationshipCopilot \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# 单元测试
xcodebuild test -project RelationshipCopilot.xcodeproj -scheme RelationshipCopilot \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# 逻辑冒烟（无需模拟器）
swiftc -o /tmp/logic-check Core/RelationshipHealth.swift Core/FulfillmentStats.swift \
  Core/AIResponseParser.swift Core/QuotaPolicy.swift Core/Validation.swift \
  Core/RelationshipType.swift Tools/logic-check/main.swift && /tmp/logic-check
```

> 归档到真机：需要在 `project.yml` 里填入 `DEVELOPMENT_TEAM`（当前为空），
> 并在 App Store Connect 创建 App ID 与 App Group `group.com.relationshipcopilot.app`。

## 配置 AI 服务

**客户端不保存任何模型厂商密钥。** 这是硬性约束（历史版本曾把密钥硬编码在源码里并提交到公开仓库）。

两种接入方式，二选一：

1. **自有代理（生产唯一形态）**
   在 `App/Info.plist` 的 `RCProxyBaseURL` 填入你的服务端地址。服务端需实现：

   ```
   POST {base}/v1/relationship/analyze
   { "conversation": "...", "counterpartName": "...", "relationshipType": "partner" }
   → { "analysis": { "score": 0-100, "summary": "...", "strengths": ["..."],
                     "improvements": ["..."], "suggestions": ["..."],
                     "emotionalTrend": "...", "communicationQuality": "..." } }

   POST {base}/v1/assist
   { "tool": "conflict|phrase|apology|checkup", "input": "..." }
   → { "text": "..." }
   ```

2. **调试直连（仅 Debug）**
   把 `RCAllowDirectKeyInDebug` 设为 `true`，`RCDirectBaseURL` 填模型端点，
   然后手动把密钥写进 Keychain 的 `rc.ai.direct_api_key`。密钥不进入源码、不进入 IPA。

未配置时，AI 功能会明确提示"AI 服务尚未配置"，**不会返回编造的结果**；
快速工具会退回到明确标注为「通用参考」的离线内容。

## 隐私

- 全部数据默认只存本机；录音写入 `Caches/Recordings`，**不进 iCloud 备份**，分析后立即删除。
- 权限只声明实际使用的三项：麦克风、语音识别、面容 ID。
- 使用 AI 分析时，仅发送**转写的文字**，不发送音频。

### 「说清一件事」的跨设备路径（唯一会让数据离开本机的功能）

默认路径完全不联网：双方在同一台手机上先后填写，两份证词都不出设备。

只有用户主动选「TA 在自己手机上写」时才会走网络，此时：

1. **发起方的那一份从不上送。** 它留在发起方手机的数据库里，服务器上只有对方那一份。
2. **对方写的内容以 AES-GCM 加密后上传。** 解密密钥只存在于链接的 `#` 之后（fragment）——按 HTTP 规范，fragment **不会发送给服务器**。所以服务器拿到的是密文，没有密钥。
3. **双方互相看不到对方的内容。** 对方提交前，发起方这边读到的永远是"TA 还没写"；反之亦然。
4. **7 天后自动过期。** 服务端 KV 条目带 TTL，到期即删；用户也可随时点「先不评了」放弃，本地密钥当场清除。
5. **评完之后密钥立即销毁。** `DisputeCase.consumeInviteKey()` 清掉密钥、只留 caseId（用于排查），此后即使链接被转发也无法再解出内容。

也就是说：**服务器只保管一段它打不开的密文，且只保管 7 天。**
风险边界要说清楚 —— 这仍然意味着数据离开了本机，只是离开的形式是密文，且解密权在用户手里。
不想有任何数据离开设备的话，用默认的「同一台手机」方式，那条路径一行网络请求都没有。

- 用户可在「我的 → 数据管理」导出或永久删除全部数据。

## 测试

三层，各自负责一个维度 —— 逻辑正确、渲染正确、视觉正确，**互不替代**：

| 层 | 位置 | 数量 | 验的是什么 |
|---|---|---|---|
| 单元测试 | `Tests/` | 237 | 纯逻辑：健康度换算、履约统计、AI 解析、配额、证词闸门、加密载荷、状态机 |
| UI 测试 | `UITests/` | 45 | 真实渲染后逐屏截图 + 布局断言（元素是否在屏内、文案是否自相矛盾、有没有未翻译英文） |
| 服务端测试 | `Tools/ai-proxy/*.test.mjs` | 116 | Worker 路由、邀请领取/提交、题型与 App 端逐字对齐 |

```bash
cd Tools/ai-proxy && npm test          # 116 项服务端断言
swiftc -o /tmp/logic-check ... && /tmp/logic-check   # 25 项无模拟器冒烟
```

> **为什么一定要截图层。** 这个项目反复出现过「断言全绿但界面是坏的」：
> 大字号下按钮被挤出屏幕、缺链接时页脚还在说"链接会失效"、
> 深色用例因为 App 本来就是深色而什么都没验证。
> 这些缺陷没有一条能被单元测试或存在性断言捕获 —— 只有把真实截图逐张看一遍才能发现。
> 相关教训写在 `UITests/ScreenshotTests.swift` 的注释里，每条断言都记着它当初是为了修什么。
