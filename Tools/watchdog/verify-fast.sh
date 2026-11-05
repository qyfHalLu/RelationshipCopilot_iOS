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

echo "▶ 1/5 Core 文件与 logic-check 清单一致性"
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

echo "▶ 2/5 logic-check 冒烟真能编译并跑通"
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

echo "▶ 3/5 服务端测试（邀请协议与 Worker）"
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

echo "▶ 4/5 邀请网页必须渲染出全部题目"
# 上一轮的真实事故：网页截图只有标题，四个问题一个都没渲染出来。
# 这条断言直接读 invite.js 源码 + 用真实路径跑一次无头 Chrome，
# 不允许再靠"看截图才发现"。
if command -v node >/dev/null && [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  if node Tools/watchdog/check-invite-page.mjs >/tmp/invpage.log 2>&1; then
    ok "$(tail -1 /tmp/invpage.log)"
  else
    bad "邀请网页渲染异常：$(tail -2 /tmp/invpage.log | head -1)"
  fi
else
  echo "  – 跳过（缺 node 或 Chrome）"
fi

echo "▶ 5/5 工作状态文件新鲜度"
if [ ! -f WORK_STATE.md ]; then
  bad "WORK_STATE.md 不存在 —— 中断后无法接手"
else
  # 允许 24 小时；超过说明有改动没记录，下一轮会拿到过期信息
  if [ -n "$(find WORK_STATE.md -mtime +1 2>/dev/null)" ]; then
    bad "WORK_STATE.md 超过 24 小时未更新 —— 进度可能没落盘"
  else
    ok "已更新（$(grep -m1 '最后一次更新' WORK_STATE.md | sed 's/.*：//')）"
  fi
fi

echo
if [ $fail -eq 0 ]; then
  printf '\033[32m全部通过，可以提交。\033[0m\n'
else
  printf '\033[31m有未通过项，先修再提交。\033[0m\n'
fi
exit $fail
