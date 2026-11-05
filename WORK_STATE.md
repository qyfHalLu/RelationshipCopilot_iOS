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

**最后一次更新**：2026-11-05 12:05

---

## 进行中

### ① 文案契约已修，待提交

**改的是什么**：`RemoteHandoverView` 里「TA 写完了」那一行，原来写死一句
**"还没提交"** —— 这是在陈述一件我们并不知道的事。

服务端用 Cloudflare KV，**最终一致，最长约 60 秒延迟**。对方刚点完提交、
我们这边立刻查，很可能查到的还是旧值。此时说"还没提交"，
用户的合理推断是"TA 在敷衍我 / 链接坏了"，而内容其实已经在服务器上。
**一次技术延迟被读成一次人际信号** —— 这个 App 处理的正是这种时刻。

改法：文案只描述**我们观察到的**，不描述对方做了什么。
- 观察到 → "还没收到 TA 那一份"（事实，可以说）
- 未观察 → "TA 还没提交"（推测，不能说）

并抽到 `Core/WaitingCopy.swift` 做成纯函数，因为放在视图里永远测不到。

- [x] 抽成 `WaitingCopy.counterpartDetail(hasWritten:missCount:)`
- [x] `invitePollCount` 原来**只增不读**，现已接进视图
- [x] 计数语义收紧：只在"请求成功但对方那份还没到"时 +1
      （请求失败不计数 —— 那时我们根本不知道对方写没写）
- [x] logic-check 新增 12 条断言，核心是钉死"任何一档都不得出现『还没提交』"
- [x] 反向验证：写回「TA 还没提交」→ 精确报红第 1 档 → 还原复绿
- [x] `xcodebuild` **BUILD SUCCEEDED**，0 error 0 warning
- [ ] **待提交**

### ② 顺带修掉一个"闸门全绿但编译失败"的口子

新增 `Core/WaitingCopy.swift` 后，六步闸门全绿，但 `xcodebuild` 报
`cannot find 'WaitingCopy' in scope`。

**根因**：这个工程**不是** `fileSystemSynchronized`，是 XcodeGen 从
`project.yml` 生成的。新文件不跑 `xcodegen generate` 就不在 target 里。
而 logic-check 走 `sources.txt`、完全不受影响 → 最坏的组合。

- [x] `verify-fast.sh` 第 1 步新增：清单内每个文件必须出现在 `project.pbxproj` 里
- [x] 反向验证：把文件名改掉模拟"未进工程" → 精确报红，
      且**第 2 步仍绿**（正好证明这个口子真实存在）→ 还原复绿
- [x] `AGENTS.md` 踩坑表补上这一条

---

## 已完成并验证（不要重复做）

### `f77d9ac` 已推送

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

1. **[高]** 提交 ①② 并推送，确认 CI 绿。
2. **[高]** **真机核验 —— 只能由用户做，本机无法替代。**
   本机能验的都验完了（四题渲染 / 409 / 无 WebCrypto 降级 / 两套主题对比度 /
   320px 窄屏），但这两件物理上测不了：
   - **微信 X5 内核**：本地只是用 CDP 抹掉 `crypto.subtle` 来模拟，
     真实 X5 给不给 WebCrypto 只有真机知道
   - **刘海屏底部安全区**：桌面 Chrome 里 `env()` 恒为 0，加了也测不出

   需要用户用手机微信打开一条真实 https 链接，确认：
   四题出现 / 输入的字看得见 / 提交有反馈 / 按钮没被手势条压住。
3. **[低]** 若真机发现 X5 不给 WebCrypto，需要考虑兜底路径：
   现在只做了"告知换浏览器"，没做"降级也能写"。这是已知最大功能缺口。
4. **[低]** 文档：`README.md` 已更新；`内测上线操作手册.md` 已加 KV 步骤。

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
