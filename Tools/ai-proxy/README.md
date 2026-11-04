# AI 代理（Cloudflare Worker）

App 的 Release 构建里不携带第三方模型密钥，`RCProxyBaseURL` 为空时内测包的
AI 功能全部不可用。这个 Worker 补上那一层：

```
App ──▶ 这个 Worker ──▶ SophNet ──▶ 模型
        （密钥只在这里）
```

## 部署（约 10 分钟）

```bash
cd Tools/ai-proxy
npx wrangler login
npx wrangler secret put SOPHNET_API_KEY   # 粘贴 SophNet 的 key
npx wrangler secret put APP_TOKEN         # 自己定一个随机串，记下来
npx wrangler deploy
```

部署完**先做这两步验证**，不要急着发内测包：

1. 浏览器打开 `https://<你的域名>/health` → 应返回 `{"ok":true,"model":"..."}`。
2. 填完下面两步后，在 App 里真做一次录音分析或快速工具，确认真出结果。

然后把地址与令牌接到 App 上：

| 值 | 填在哪 | 存在哪 |
|---|---|---|
| `https://<你的域名>`（末尾不带斜杠） | `App/Info.plist` → `RCProxyBaseURL` | 随包分发 |
| `APP_TOKEN` 的同一个值 | App 设置页 →「内测代理令牌」 | Keychain（设备内） |

令牌进 Keychain 目前是**手动**流程，这是已知缺口：内测只有个位数用户，
先把链路跑通；要做成自动下发，需要先有账号体系。

## 端点

| 方法 | 路径 | 请求 | 响应 |
|---|---|---|---|
| POST | `/v1/assist` | `{tool, input}` | `{text}` |
| POST | `/v1/dispute/evaluate` | `{systemPrompt, userMessage, temperature, maxTokens}` | `{text}` |
| POST | `/v1/relationship/analyze` | `{conversation, counterpartName, relationshipType}` | `{analysis}` |
| GET | `/health` | — | `{ok, model}` |

除 `/health` 外，全部需要请求头 `x-app-token`。

## 契约的唯一权威是 Swift 源码

`Services/AIService.swift` 里的 `ProxyAnalyzeRequest` / `AssistRequest` /
`DisputeProxyRequest` 才是契约。这里的注释不是。

这条规矩是被一次真实故障换来的：`analyze` 端点曾经读 `transcript`，而客户端
发的是 `conversation`。**代理对上真实客户端是 100% 的 400**，而当时的 18 项
测试全绿——因为测试自己把请求体写成了 `transcript`。测试在测一个不存在的客户端。

所以 `worker.test.mjs` 现在直接读 Swift 源码取出字段名来构造请求。Swift 那边
改名，这里立刻报红。**改这个代理之前先跑 `node worker.test.mjs`。**

## 两个刻意的设计

**不设 CORS。** 这个 Worker 只给原生 App 用，不需要浏览器跨域。开着会让别人的
网页也能拿你的额度。

**上限内的软配额 + 缺失即放行。** 按 IP 每天 30 次，用 Cache API 存，不引 KV。
它只防"顺手刷"，不防换 IP。Cache 不可用时**放行**——配额是尽力而为的软限制，
不该因为它自己出问题就把服务变成不可用。

## 已知缺口

- **`APP_TOKEN` 需手动写入 Keychain**：见上，内测期可接受。
- **配额在客户端也有一份**（`QuotaPolicy`），重装即重置。真正的计费口径必须在
  服务端按账号做，而内测没有账号。
- **无内容审核**：走的是模型自身的安全拒答 + `ANALYSIS_PROMPT` 里的自伤/暴力
  兜底。上架前需要补。

## 关于旧的 `relcopilot_proxy/`

工作区根目录曾有一份更早的同名实现（`src/worker.js`，391 行，缺令牌校验、
`/health` 只接受 POST、把上游错误体原样回传、`analyze` 读的是 `transcript`）。
那份代码**从未进入 git**，2026-11-04 已删除，只在
`/tmp/relcopilot_proxy_backup_20261104.tar.gz` 留了一份本地备份。

删除前核对过能力：3 个业务端点 + `health` 全部覆盖，测试断言从 39 条增至 56 条
（实际运行 61 项）。留着的唯一后果是「照着错的改」——两份实现的字段名分歧已经
导致过一次真实故障，所以不留参照物是刻意的。
