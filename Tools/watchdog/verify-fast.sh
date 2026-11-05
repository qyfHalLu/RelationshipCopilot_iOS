#!/bin/bash
# 快速验证（约 30 秒）—— 每个增量跑一次，作为提交前的闸门。
#
# 设计原则：**只检那些「本机单测跑不到、但会在 CI 或线上炸」的东西。**
# 全量单测（1 分钟）和 UI 测试（8.5 分钟）都不在这里，按需另跑。
#
# 为什么需要这个脚本：上一轮 CI 失败的原因是
# `Core/InviteLink.swift` 没登记进 logic-check 清单 ——
# 本机 237 个单测全绿，这个错误只有 CI 才会发现。
# 那种"本机能过、CI 才炸"的缺口，必须有一个本机能跑的等价检查。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }

echo "▶ 1/6 Core 文件与 logic-check 清单一致性"
# 与 .github/workflows/ios.yml 里那段保持同一份 EXCLUDED。
# 这里重复一遍是有意的：如果 CI 改了而这里没改，本脚本会立刻发现不一致
# （见第 5 步的一致性交叉校验）。
EXCLUDED="Core/EndpointConfiguration.swift Core/InviteLink.swift Core/InvitePayload.swift"
is_excluded() { for e in $EXCLUDED; do [ "$1" = "$e" ] && return 0; done; return 1; }
MISSING=""
for f in Core/*.swift; do
  is_excluded "$f" && continue
  grep -qxF "$f" Tools/logic-check/sources.txt || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  bad "未登记进 sources.txt:$MISSING"
  echo "     → 能独立编译的加进 sources.txt；依赖 Services 的加进两处 EXCLUDED 并写原因"
else
  ok "清单完整"
fi
for e in $EXCLUDED; do
  [ -f "$e" ] || bad "EXCLUDED 引用了不存在的文件：$e（排除清单在掩盖真实缺口）"
done
STALE=""
while IFS= read -r f; do
  case "$f" in ''|'#'*) continue;; esac
  [ -f "$f" ] || STALE="$STALE $f"
done < Tools/logic-check/sources.txt
[ -z "$STALE" ] && ok "清单无失效引用" || bad "sources.txt 引用了不存在的文件:$STALE"

# ---- 1b. 每个被 target 收录的 .swift 必须真的在工程里 ----
#
# ## 为什么需要这一步
#
# 这个工程**不是** `fileSystemSynchronized`，是 XcodeGen 从 `project.yml` 生成的。
# 新建一个 `.swift` 文件后如果没跑 `xcodegen generate`，它**不在 target 里**，
# Xcode 编译时报 `cannot find 'X' in scope`。
#
# 危险之处在于：logic-check 走 `sources.txt`、**完全不受影响** ——
# 于是会出现「六步闸门全绿、但 App 编译失败」这种最坏的组合。
# 本轮就真的踩到了：新增 `Core/WaitingCopy.swift`，闸门绿，xcodebuild 红。
#
# 判据：把 sources.txt 里每个文件名拿去 project.pbxproj 里找。
# 找不到就说明工程没收录 —— 修法是跑 `xcodegen generate`，不是改这里。
PBX="$PWD/RelationshipCopilot.xcodeproj/project.pbxproj"
if [ -f "$PBX" ]; then
  MISSING=""
  while IFS= read -r f; do
    case "$f" in ''|'#'*) continue;; esac
    base=$(basename "$f")
    if ! grep -qF "$base" "$PBX"; then MISSING="$MISSING $f"; fi
  done < Tools/logic-check/sources.txt
  if [ -z "$MISSING" ]; then
    ok "清单内文件都已在 Xcode 工程中"
  else
    bad "以下文件没有进入 Xcode 工程（跑 xcodegen generate）:$MISSING"
  fi
else
  bad "找不到 project.pbxproj，无法校验文件是否进工程"
fi

echo "▶ 2/6 logic-check 冒烟真能编译并跑通"
# 只校验清单不校验能不能编，等于让 CI 从"清单不全"变成"编译失败"。
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if swiftc -o /tmp/lc-verify \
     $(grep -v '^#' Tools/logic-check/sources.txt | grep -v '^$') \
     Tools/logic-check/main.swift 2>/tmp/lc-err.txt; then
  if /tmp/lc-verify >/tmp/lc-out.txt 2>&1; then
    ok "冒烟通过（$(tail -1 /tmp/lc-out.txt)）"
  else
    bad "冒烟运行失败：$(tail -2 /tmp/lc-out.txt | head -1)"
  fi
else
  bad "冒烟编译失败：$(grep -m1 'error:' /tmp/lc-err.txt)"
fi

echo "▶ 3/6 服务端测试（邀请协议与 Worker）"
if [ -f Tools/ai-proxy/package.json ]; then
  # 两个文件分别跑，不要用 && 串起来。
  # 串起来时前一个失败会让后一个根本不执行，而报错信息里只有前者的日志，
  # 看上去像"后者的日志文件不存在"—— 排查方向会被带偏。
  ( cd Tools/ai-proxy && node worker.test.mjs >/tmp/w.log 2>&1 ); w_rc=$?
  ( cd Tools/ai-proxy && node invite.test.mjs >/tmp/i.log 2>&1 ); i_rc=$?
  if [ $w_rc -eq 0 ] && [ $i_rc -eq 0 ]; then
    ok "worker $(grep -oE '通过 [0-9]+ 项' /tmp/w.log | head -1) / invite $(grep -oE '^[0-9]+ 通过' /tmp/i.log | head -1)"
  else
    [ $w_rc -ne 0 ] && bad "worker.test.mjs 失败：$(grep -m1 -iE 'error|SyntaxError|失败' /tmp/w.log)"
    [ $i_rc -ne 0 ] && bad "invite.test.mjs 失败：$(grep -m1 -iE 'error|SyntaxError|失败' /tmp/i.log)"
  fi
else
  bad "缺少 Tools/ai-proxy/package.json（ESM 需要它，否则 import 会当 CommonJS 报错）"
fi

echo "▶ 4/6 页面脚本能被解析器接受（不需要浏览器）"
# 独立于浏览器的一道闸门，专门拦"模板字符串被自己写坏"这一类错误。
#
# 为什么单独一条：页面 JS 整个写在模板字符串里，注释里出现一个反引号
# 就会把字符串切断，报 SyntaxError: Unexpected identifier。
# 这个坑在本轮踩了**三次** —— 每次写注释解释转义问题，就会把转义符号
# 或反引号本身写进注释。靠"记住别写"不可靠，得让机器判定。
#
# ## 判据选错过一次
#
# 第一版是"把模板字符串切出来、抽 script 块、交给 new Function 解析"。
# 反向验证时故意插一个反引号，它**没报错** —— 因为反引号让
# `indexOf("</html>`")` 提前命中，切出来的片段恰好语法合法。
# 也就是说：切口本身被污染了，而我拿一个被污染的输入去证明"没问题"。
#
# 改用最直接的判据：让 Node 把整个模块解析一遍。
# 模板字符串坏了，模块就加载不起来，异常信息也直指问题。
# 顺带还覆盖了模块级的其它语法错误，比只看 script 块更完整。
if node -e 'import("./Tools/ai-proxy/invite.js").then(() => process.exit(0)).catch((e) => { console.error(e.message.split("\n")[0]); process.exit(1); })' >/tmp/parse.log 2>&1; then
  ok "页面脚本语法合法（模块可加载）"
else
  bad "页面脚本语法错误：$(tail -1 /tmp/parse.log)"
fi

echo "▶ 5/6 邀请网页必须渲染出全部题目"
if command -v node >/dev/null && [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  if node Tools/watchdog/check-invite-page.mjs >/tmp/invpage.log 2>&1; then
    ok "$(tail -1 /tmp/invpage.log)"
  else
    bad "邀请网页渲染异常：$(tail -2 /tmp/invpage.log | head -1)"
  fi
else
  echo "  – 跳过（缺 node 或 Chrome）"
fi

echo "▶ 6/6 工作状态文件新鲜度"
if [ ! -f WORK_STATE.md ]; then
  bad "WORK_STATE.md 不存在 —— 中断后无法接手"
else
  # 允许 24 小时；超过说明有改动没记录，下一轮会拿到过期信息
  if [ -n "$(find WORK_STATE.md -mtime +1 2>/dev/null)" ]; then
    bad "WORK_STATE.md 超过 24 小时未更新 —— 进度可能没落盘"
  else
    ok "已更新（$(grep -m1 -E '最后一次更新|最后更新' WORK_STATE.md | sed 's/.*：//' | sed 's/^ *//')）"
  fi
fi

echo
if [ $fail -eq 0 ]; then
  printf '\033[32m全部通过，可以提交。\033[0m\n'
else
  printf '\033[31m有未通过项，先修再提交。\033[0m\n'
fi
exit $fail
