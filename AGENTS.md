# AGENTS.md —— 给「下一个我」的接手契约

> 这份文件的唯一目的：**让上下文中断不产生任何损失**。
>
> 这个环境会频繁因 `Model tpm limit exceeded` / upstream 超时 / 网络抖动
> 而把会话从中间掐断。掐断时上下文全丢，但如果进度落在磁盘上、
> 每个增量都已验证并提交，那么下一轮只需要很小的一次读取就能原地续上。
>
> **任何新会话，第一件事是读 `WORK_STATE.md`，不是读代码。**

---

## 三条硬规则

### 1. 一次只做一个可验证的增量

不要开一个"要改 8 个文件"的大任务再慢慢调。顺序是：

```
读 WORK_STATE.md → 取「进行中」的第一条 → 做最小的完整一步
→ 跑 verify-fast → 更新 WORK_STATE.md → commit
```

一个增量 = 一次能跑完验证 + 写得进一句 commit message 的改动。
中断最多丢一个增量，而不会丢一个方向。

### 2. 「写完」不等于「验证过」

`WORK_STATE.md` 里「进行中」和「已完成并验证」必须严格分开。
只有**跑过验证并贴了数字**的才能移到已完成。
把没验证的东西写成已完成，比不写更糟 —— 下一轮会信以为真。

### 3. 花钱的地方要克制

token 是按量计的，`Model tpm limit exceeded` 就是花超了。

- UI 全量测试 **8.5 分钟**，不要每次改动都跑。放后台，或只跑相关用例。
- 每个增量只跑 `Tools/watchdog/verify-fast.sh`（约 30 秒，覆盖最容易漏的几种失败）。
- 输出必须 `grep` 过滤，不要把整个构建日志读进上下文。
- 读文件用 Grep 定位段落，不要整篇读 3000 行的文件。

---

## 中断恢复流程（照抄即可）

```bash
# 1. 看现状（这一步会打印出该干什么，不用另外分析）
bash Tools/watchdog/resume-brief.sh

# 2. 按它给的「下一步」做，做完：
bash Tools/watchdog/verify-fast.sh

# 3. 更新 WORK_STATE.md 的「进行中 / 已完成」与时间戳

# 4. 提交（小步提交是抗中断的根基，不是洁癖）
git add -A && git commit -m "<做了什么>"
```

---

## 这个项目的特殊约束（踩过的坑，别再踩）

| 约束 | 说明 |
|---|---|
| 构建 | **必须**加 `OTHER_SWIFT_FLAGS='-disable-sandbox'`，否则宏插件沙箱报错 |
| `grep` | 本机是 BSD 版，**不支持 `\|` 交替**，一律用 Grep 工具 |
| Chrome | 无头必须加 `--no-sandbox` |
| 新增 Core 文件 | **三件事都要做**：① 登记 `Tools/logic-check/sources.txt`；② **跑 `xcodegen generate` 重新生成工程**；③ 依赖 Services 的进 CI 的 `EXCLUDED` 并写明原因 |
| 依赖 Services 的 Core 文件 | 不能进 logic-check（会 `cannot find type`），进 `EXCLUDED` |
| **新文件不进工程** | 这个工程**不是** `fileSystemSynchronized`，是 XcodeGen 从 `project.yml` 生成的。新 `.swift` 文件不跑 `xcodegen generate` 就**不在 target 里**，编译报 `cannot find 'X' in scope`。危险在于 logic-check 走 `sources.txt`、不受影响 → **闸门全绿但 Xcode 编译失败** |
| 截图 | 必须带 `-resultBundlePath`，再用 `xcrun xcresulttool export attachments` 导出 |
| **判断 import 能否删** | **不许用 `grep` 静态查，只能"删掉再 `xcodebuild`"。** 实例：`SettingsView` 里的 `import StoreKit` 看着毫无用处（无 `Product`/`purchase`/`Transaction`），实际 `@Environment(\.requestReview)` 的 `RequestReviewAction` 就是 StoreKit 提供的 —— 删掉立刻 `generic parameter 'Value' could not be inferred`。**间接类型引用静态查不到** |
| **判断函数是否死代码** | 先 `grep -rn` 查全仓库（含子目录），再**删掉编译**双确认。上一轮只因命令漏了子目录，就把还在用的 `SafeLog.maskedPhone` 判成"零调用" |
| **同一个 View 有 tab 根页 + push 两种入口** | **只能有一个建 `NavigationStack`。** tab 根页必须自建；被 push 时必须不建。两边都建 = 栈套栈，表现为「点一下没反应 / 进去又弹回来 / 没有返回按钮」，而 SwiftUI **不报错也不警告**。开关见 `DisputeListView.ownsNavigationStack` |
| **验"偶发"的导航缺陷** | 单次点击的用例几乎必然假绿。必须**循环点 N 次 + 每次断言"还在" + 断言"退得回来"**，再把旧实现放回去跑一遍，确认它真的会红 |
| **文案类断言（性别 / 措辞）** | 别用手工挑的组合去匹配 —— 那只能覆盖你想到的写法。本项目的性别词表只列了 `她`/`他先`/`让他`，于是 `怕他发火`、`错不在他` 全部漏网，测试全绿而界面满是「他」。正确做法是「剔除已知中性词后扫单字」+ 一条反向验证用例 |
| 断言全绿 | **不代表界面对**。这个项目四次出事都是断言绿、截图坏 |
| 深色用例 | App 默认就是暗色，测「深色」等于什么都没测，要测**亮色** |

---

## 验收标准（什么叫"这个增量做完了"）

- [ ] `verify-fast.sh` 全过
- [ ] 涉及界面的改动：**看过截图**，不是只看断言
- [ ] `WORK_STATE.md` 已更新（含时间戳）
- [ ] 已 `git commit`
- [ ] 如果有新发现但没做，写进 `WORK_STATE.md` 的待办，不要留在脑子里

---

## 禁止

- 不要为了"看起来完成"而删除失败的测试或放宽断言阈值。调阈值迁就缺陷是被明确禁止的。
- 不要在没跑验证的情况下把条目移到「已完成并验证」。
- 不要一次性重写大段代码。中断后无法分辨哪一半是对的。
- 不要在 `file://` 下判断网页行为（`location.pathname` 不成立，会得到假缺陷）。
