# 工作进度状态（供中断后接手）

> **这个文件是给"下一轮的我"看的，不是给人看的文档。**
>
> 会话会因为模型配额（`Model tpm limit exceeded`）、upstream 超时、网络中断
> 而随时断开。上下文一断，进度就没了。所以进度必须落在磁盘上：
> 任何一次新的会话，**先跑 `bash Tools/watchdog/resume-brief.sh`**，
> 它会直接打印"现在在哪、下一步做什么"，不需要重新推理一遍。
>
> 维护规则：
> - 每完成**一个可验证的动作**就更新一次（不是每写完一段代码）。
> - 「进行中」和「已完成并验证」必须严格分开。写完但没跑的，一律算未完成。
> - 上一轮留下的"进行中"如果没有结论，接手时**先复跑一次验证**，不要相信文字。

**最后一次更新**：2026-11-05 15:02
（历次误记过 12:55 / 12:25。本轮以 `date` 实测时间为准，别再手写推算。）

---

## 进行中

### ① 本轮（15:00 起）处理用户报的 5 个问题 —— 已提交 `2713a51`，CI **success**（`41985582423`）

| # | 用户报告 | 结论 | 状态 |
|---|---|---|---|
| 1 | 对话分析里「冲突复盘」卡片格式和别的不一样 | 右侧**缺 chevron**，且文字块顶对齐（与「录一段」差 2.4pt） | 已修 |
| 2 | 「把一件事说清」偶发进不去 / 进去又退出 | `DisputeListView` 自带 `NavigationStack` 又被 push → **栈套栈** | 已修，**反向验证证实** |
| 3 | 短文字输入不该有语音 | 承诺内容、关系备注 ×2 三处移除；长文本保留 | 已修 |
| 4 | 两人评理只有「同一台手机」，没有邀请链接 | `NewDisputeSheet` 从未提供 `.remote`，整条远程链路用户走不到 | 已修 |
| 5 | 道歉准备：妇联默认性别 + 一进去就说「先别急着道歉」 | 热线换成 110 / 12356；持久化的 `fearedReaction=true` 被直接沿用 | 已修 |

**问题 2 的反向验证（关键证据）**：把 `DisputeListView()` 改回自建栈后，
新用例立刻报 **「第 1 次进入后被自动弹回来了」+「评理页没有返回按钮」**；
改回 `ownsNavigationStack: false` 后连过 3 轮。诊断不是猜的。

**顺带发现的一个测试洞（比 5 个 bug 更值得记）**：
`GenderNeutralCopyTests` 原先只匹配手工挑的组合（`她`/`他先`/`让他`…），
单字「他」被刻意排除 —— 于是 `怕他发火`、`错不在他`、`他失去了什么`
全部漏网，**测试全绿而界面满是「他」**。
改成"剔除中性复合词（其他/他人/…）后扫描 `他`/`她`"，并加反向验证用例；
扫描文件从 5 个扩到 11 个，一次抓出 **19 处**，已全部改成 TA。

### ② 真机核验 —— 仍然只能由用户做
| `f80ea1b` | 连不上服务端时不再断言「TA 还没有打开」 | `41977160475` |

本机能验的全部验完了，逐项证据：

| 项 | 手段 | 结果 |
|---|---|---|
| 四题真实渲染 | CDP 真执行 | 4/4 |
| 链接已提交(409) | 反向场景 | 有明确提示，不渲染输入框 |
| 无 WebCrypto | 注入降级 | 有中文指引，不渲染输入框 |
| 两套主题对比度 | 计算样式 | 五组全 ≥4.5:1 |
| 320px 窄屏 | 截图 | 无溢出无裁切 |
| 文案措辞 | logic-check 12 条 | 钉死"不许替对方下判断" |
| 远程交接屏 | UI 截图 | 「还没收到 TA 那一份」正确显示 |
| XXXL 大字号 | UI 截图 + 坐标 | 文案不截断，滚到底 gap=120pt |

**测不了的两件**（物理限制，不是没做）：
- **微信 X5 内核**：本地只是用 CDP 抹掉 `crypto.subtle` 模拟，
  真实 X5 给不给 WebCrypto，只有真机知道
- **刘海屏安全区**：桌面 Chrome 里 `env()` 恒为 0，加了也测不出

**需要用户做**：手机微信打开一条真实 https 邀请链接，确认四题出现 /
输入的字看得见 / 提交有反馈 / 按钮没被手势条压住。

#### 巡检记录（2026-11-05 13:27 起，本轮）

**状态判断：不是「无待办」，也不是「中断未恢复」—— 是并发。**

进入时 `resume-brief.sh` 报「未提交 5 个 Core 文件、领先远端 0、
最后更新 12:25（62 分钟前）」，按规则 3 本该判为中断。**但继续查发现不是**：

- 实际是**另一个会话/进程正在同时干活**，它在 13:38 提交了 `de0d31b`
  并推送，CI `41975244229` **success**（5m55s）。
- 我逐项核过 `de0d31b` 的内容与自己的结论一致：那 5 个函数确为全仓库零真实
  调用（`grep` 全子目录 + 删后 `xcodebuild` 双确认），删得对。
- 教训：`resume-brief.sh` 只看「未提交 + 领先远端」，**看不出工作区正在被
  另一个进程改写**。判「中断」前应先看 `git log` 有没有比简报所报 HEAD 更新的提交。

**本轮真正新增的增量：一处会误导人的注释。**

`Core/QuotaPolicy.swift` 里 `de0d31b` 留下的说明是：

> `QuotaSnapshot.fresh` 已删除；**快照的实际生成在 `AIService.checkAndResetDailyQuota()` 里**。

前半句对（确实零调用），**后半句是错的**。实测：

- `checkAndResetDailyQuota()`（`Services/AIService.swift:692`）读写的是
  UserDefaults 两个独立键（`Keys.used` / `Keys.lastDay`，见 `persistQuota()`），
  **从不构造 `QuotaSnapshot`**。
- 并且 `QuotaSnapshot` **这个类型本身**也全仓库零引用（`grep` 只命中它自己的定义）。
  顺带发现文件头提到的 `AIQuotaStore` 也**不存在**，同样只出现在注释里。

已把该注释改成事实描述，并写明「删整个类型属另一次增量，见待办」。
**没有删类型**——本轮只做一个可验证增量。

**验证（都真跑了，不是推断）**：

| 项 | 命令 | 结果 |
|---|---|---|
| 闸门六步 | `verify-fast.sh` | 全绿（worker 61 / invite 55 / 对比度五组 ≥4.5） |
| Swift 编译 | `xcodebuild build`（`DEVELOPER_DIR=/Applications/Xcode.app/...`） | **BUILD SUCCEEDED**，0 warning |
| 单测 | `-only-testing:RelationshipCopilotTests` | **237 项 0 失败** |
| UI 测试 | 全 scheme | **45 项 0 失败**，2 项缺 `RC_TEST_AI_KEY` 按设计跳过 |
| 零调用复核 | `grep` 全仓库（含所有子目录，非仅根目录） | 只命中注释，无真实调用 |

**环境坑（新发现，记下来别重踩）**：
`xcodebuild` 直接调会报 `requires Xcode, but active developer directory is
CommandLineTools`。本机装的是 **Xcode 27.2**，必须前缀
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，**不要**去跑
`xcode-select --switch` 改全局设置。另外：**没有 iPhone 16 这个模拟器**，
可用的是 iOS 27.0 的 `iPhone 18 Pro` / `iPhone 17` 等，写错设备名会静默
回退到 `My Mac` 并报 platform 不匹配。

本轮无界面改动，故未截图（`shoot-invite-page.mjs` 不适用）。

#### 巡检记录（2026-11-05 12:25，上一轮）

- `resume-brief.sh`：未提交 0 个、领先远端 0 个、HEAD `326e55e`。
- `verify-fast.sh`：**六步全绿**（Core 清单一致 / 冒烟 / worker 61 + invite 55 /
  脚本可解析 / 四题渲染 + 浅色对比度 15.86·16.95·5.26·16.41·6.14 / 新鲜度在期）。
- 结论：**本机可做的都已做完，无新增可验证增量**。
  按巡检规则"只剩真机操作时不重复尝试"，本轮不再改动代码，
  **卡在真机核验，等待用户**。
- 下一轮巡检若仍处于此状态：只复跑 `verify-fast.sh`，不要发明新任务，
  也不要把它当成"上一轮中断"。

---

## 已完成并验证（不要重复做）

### `de0d31b` 已推送 —— 代码质量清理（用户要求"全部执行"）

**A 类：删 10 处零引用函数（约 65 行）**

| 位置 | 函数 | 判断依据 |
|---|---|---|
| `Core/AppLog.swift` | `SafeLog.textLength` | 全仓库零调用 |
| `Core/DisputeEvaluation.swift` | `DisputeRequest.gateRejection(state:)` | 纯转发；UI 直接调 `DisputeCaseGate.check` |
| `Core/GuidedRepair.swift` | `RepairLinter.trimmedCount` | 私有且零调用 |
| `Core/Telemetry.swift` | `hasEverFired(_:)` | 等价于 `count(of:) > 0`，无人用 |
| `Core/QuotaPolicy.swift` | `QuotaSnapshot.fresh(today:)` | 实际生成在 `checkAndResetDailyQuota` |
| `Presentation/Theme/ThemeManager.swift` | `View.gradientBackground()` | 零调用 |
| `Services/AIService.swift` | `generateHealthReport(for:sessions:)` | 零调用 |
| `Services/AIService.swift` | `resetDailyQuota()` | 零调用；跨天自动重置，无死锁 |
| `Services/NotificationService.swift` | `setBadge(_:)` | 零调用；本 App 只用 `clearBadge()` |

每处原位留说明，写清「为什么没被用」+「将来怎么加回来」。

**B 类：合并 `extractJSONObject`（40 行 → 1 行转调）**

⚠️ **这里纠正了一条上一轮的误判，务必记住**：
上一轮我说「`DisputeVerdictParser` 版不剥围栏，模型给 ``` 就解析失败」——
**实测不成立**。围栏标记（`json` / 空）里没有 `{`，从第一个 `{` 起提取照样正确。
真正的分叉只有一个窄边界：**围栏前恰好出现带花括号的说明文字**
（`说明{见下}：\n```json\n...``` ` → 旧版取到 `{见下}`）。
定性从「高频故障」改为「窄边界更脆弱」，但仍然值得合并。

**测试**：`logic-check` 补 22 条断言（9 个输入 × 2 + 4 条兜底）。
反向验证注入旧实现 → **精确失败 2 项**（正是那条边界用例），
其余 120 项全绿 → 证明断言非恒真；还原后 122 项全绿。

**C 类：删 4 处未使用 import**
`AuthenticationService`(CryptoKit) / `MetricsReporter`(os)
/ `NotificationService`(UIKit) / `AIService`(SwiftData)

### ⚠️ 踩坑：`import StoreKit` **不能删**
`SettingsView` 的 `@Environment(\.requestReview)` 里，`RequestReviewAction`
是 StoreKit 提供的。删掉 import 直接编译失败（`generic parameter 'Value'
could not be inferred`）。
**为什么静态检查查不出来**：我用 `grep "StoreKit|Product|purchase|Transaction"`
查使用情况，这种**间接类型引用完全命中不到**。
**今后规则**：判断 import 是否可删，一律以「删掉后 `xcodebuild`」为准，
不以静态 grep 为准。这次是靠编译当场抓住的，不是靠推理。

### 两处**主动偏离**原清理建议（已确认保留）

- **`Promise.reopen()`**：`close()` 是达标后**自动触发**的
  （`ContentView.swift:357-359`），用户没有选择余地。`reopen()` 是这条自动
  路径**唯一的撤销入口**，删掉会把「自动关闭后无法恢复」变成永久缺陷。
- **`SafeLog.maskedPhone()`**：我上一轮误判为「零调用」，实际有 2 处真实调用
  （`AuthenticationView.swift:170`、`MeView.swift:132`）。删了会把完整手机号
  直接显示在界面上。**教训**：上一轮的命令只查了根目录，漏了子目录。

### 明确**暂不动**的一类
`Profile` / `Promise` 上的 `@Model` 死字段 —— 删字段涉及 SwiftData schema
迁移，风险远大于收益，等有真实用户数据后再评估。

### `759cf49` 已推送，CI `41963264975` **success**

- **记录一个假缺陷**：04e 首屏截图看着像被 tab bar 切成半行，
  实测「现在到哪一步了」`minY=842` 而 `tabTop=791` —— 整个在栏下方，
  首屏根本没露头。那半行是**滚动中途**拍到的。
  我第一版据此加的断言因 `minY < tabTop` 这个错误条件而恒真，
  已删除，只留注释记坐标（无代码改动）。

### `ed4298c` 已推送，CI `41962022487` **success**

- **文案契约**：远程交接屏原写死「还没提交」—— 那是在陈述我们并不知道的事
  （KV 最终一致，最长 60 秒延迟）。改为只说观察到的「还没收到 TA 那一份」，
  抽到 `Core/WaitingCopy.swift` 纯函数 + 12 条断言钉死。
  `invitePollCount` 原先**只增不读**，已接进视图并收紧计数语义。
- **堵掉「闸门全绿但编译失败」的口子**：新增 Core 文件没跑 `xcodegen generate`
  就不在 target 里，而 logic-check 走 sources.txt 不受影响。
  `verify-fast.sh` 新增"清单内文件必须在 project.pbxproj 里"，
  反向验证时**第 1 步红、第 2 步仍绿**，当场证明口子真实存在。
- **视觉核验**：远程交接屏常规 + XXXL 两张截图看过，
  新文案完整显示、无截断、滚到底 gap=120pt。

### `f77d9ac` 已推送，CI success

- **浅色主题下题号/输入文字不可见（对比度 1.06:1）**：
  根因是 `@media light` 覆盖块写在深色规则之前、特异性相同 → 后写的赢，
  只有 `body` 生效。改为 `:root` 一组 `--var` 单一来源。
  检查器新增 3b 段：两套主题 × 五组颜色算 WCAG 对比度，阈值 4.5:1，
  带样本数下限 + 解析失败抛错；反向验证精确报红。
- **顺带**：`::placeholder` 显式配色、`-webkit-text-size-adjust`、
  底部 `env(safe-area-inset-bottom)` 补偿。
- **视觉核验**：浅色 / 深色 / 320px 三张截图逐张看过，无溢出与裁切。

- **邀请网页整页 JS 不执行的语法错误**：模板字符串里写成 `\\/` →
  浏览器收到 `\\` → 正则提前闭合 → `SyntaxError: Invalid regular expression flags`
  → 整段脚本一行都不执行，对方只看到空白。
  （详见该提交信息，教训在 `Tools/watchdog/check-invite-page.mjs` 顶部注释。）
- **CI 清单校验**：两个依赖 `InviteSecret` 的 Core 文件改走 `EXCLUDED`，
  并加了"排除清单必须真实存在"的反向校验。
- **抗中断机制**：`WORK_STATE.md` / `AGENTS.md` / `Tools/watchdog/`（三件套）。
- CI run `41955842570` **success**（7m20s）。

### 更早完成

- 跨设备邀请全链路：链接生成 / 网页填写 / 加密回传 / 解密推进 / 结果展示。
- 单测 **237** 全过；UI **45** 全过（2 项缺 `RC_TEST_AI_KEY` 按设计跳过）。
- 服务端 **116** 全过（worker 61 + invite 55）。
- Debug 构建 0 warning。
- 截图核验：远程交接首屏 / 滚到底 / 缺链接 / 亮色 / XXXL（首屏 + 滚到底）。
- 修掉的界面缺陷（均有截图存证）：
  - 缺链接页脚仍说「链接 7 天后失效」→ 整句不显示（同屏已说三遍"已保存"）。
  - 说明与卡片重复表述 → 分工「说明说状态、卡片说出路」。
  - 链接缩写渲染成 `page…` → 改显示 caseId 前缀。
  - XXXL 链接卡片被推出首屏 → 紧凑顺序 + 按钮上下堆叠。
  - 红条显示英文系统错误 → `URLError` 译中文 + 断言禁未翻译英文。
  - 深色用例与默认图逐像素相同（App 本就暗色）→ 改跑亮色 + scheme 探针。

---

## 待办（按优先级）

1. **[高]** ~~提交 ①② 并推送，确认 CI 绿。~~ **已完成**：
   `de0d31b` 已推送，CI `41975244229` success。此项作废，别再找「①②」是什么。
2. **[高]** **真机核验 —— 只能由用户做，本机无法替代。**
   本机能验的都验完了（四题渲染 / 409 / 无 WebCrypto 降级 / 两套主题对比度 /
   320px 窄屏），但这两件物理上测不了：
   - **微信 X5 内核**：本地只是用 CDP 抹掉 `crypto.subtle` 来模拟，
     真实 X5 给不给 WebCrypto 只有真机知道
   - **刘海屏底部安全区**：桌面 Chrome 里 `env()` 恒为 0，加了也测不出

   需要用户用手机微信打开一条真实 https 链接，确认：
   四题出现 / 输入的字看得见 / 提交有反馈 / 按钮没被手势条压住。
3. **[中]** 删掉死类型 `QuotaSnapshot`（`Core/QuotaPolicy.swift:42`）。
   已确认全仓库零引用，且 `AIService` 的配额完全不经过它。
   **一次做干净**：删类型 → 查 `Tests/*.swift` 里是否有它的单测一并删 →
   `verify-fast.sh` → `xcodebuild` → 提交。别只删一半。
   注意：**不是** `de0d31b` 那条注释说的「实际生成在
   `checkAndResetDailyQuota` 里」，那句是错的，本轮已改掉。
4. **[中]** `Core/QuotaPolicy.swift` 文件头注释提到 `AIQuotaStore`，
   但该类型**不存在**。要么把注释改成描述真实的 `AIService` + UserDefaults
   方案，要么补上这个类型。现在这句会误导人去找一个不存在的文件。
5. **[低]** 若真机发现 X5 不给 WebCrypto，需要考虑兜底路径：
   现在只做了"告知换浏览器"，没做"降级也能写"。这是已知最大功能缺口。
6. **[低]** 文档：`README.md` 已更新；`内测上线操作手册.md` 已加 KV 步骤。


---

## 抗中断机制（本文件属于它的一部分）

| 东西 | 作用 |
|---|---|
| `AGENTS.md` | 接手契约：三条硬规则 + 项目踩坑表 + 禁止事项 |
| `WORK_STATE.md` | 本文件。进度落盘，"进行中"与"已完成"严格分开 |
| `Tools/watchdog/resume-brief.sh` | 一条命令打印"现在在哪、下一步做什么"，约 10 行 |
| `Tools/watchdog/verify-fast.sh` | 六步闸门，约 30 秒，提交前必跑 |
| `Tools/watchdog/check-invite-page.mjs` | CDP 真执行页面 + 对比度断言 |
| `Tools/watchdog/shoot-invite-page.mjs` | 真截图（浅色/深色/窄屏） |

**定时巡检**：已建自动化任务「关系副驾 · 每 30 分钟进度巡检」。

⚠️ 实际周期是**每小时**，不是每 30 分钟 —— 调度器只支持
`HOURLY / DAILY / WEEKLY / MONTHLY / YEARLY` 这几种频率，
没有"每 30 分钟"这个粒度，`FREQ=HOURLY;INTERVAL=1` 已是最细。
这一点不要在下轮重新"发现"一次。

---

## 环境备忘

- 构建必须带 `OTHER_SWIFT_FLAGS='-disable-sandbox'`。
- 截图导出：`xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`。
- 跑测试要带 `-resultBundlePath`，否则拿不到图。
- 本机 `grep` 是 BSD 版，不支持 `\|` 交替，一律用 Grep 工具。
- Chrome 无头必须加 `--no-sandbox`，且要给独立 `--user-data-dir`。
- **不要用 `--dump-dom` 判断页面是否正常**：它返回的是未执行 JS 的初始 DOM，
  长度和源文件一样，看上去"加载正常"，实际什么都没发生。要用 CDP。
- `chrome --headless --dump-dom` 在 Node 的 `execFileSync` 里会挂到超时
  （Chrome 主进程不退出），要用 spawn + 拿到 `</html>` 就 kill。
- UI 全量约 8.5 分钟，单测约 1 分钟 → 全量回归放后台。
