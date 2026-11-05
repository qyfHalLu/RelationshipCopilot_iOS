#!/bin/bash
# 中断后接手简报 —— 一条命令说清"现在在哪、下一步做什么"。
#
# 用法：bash Tools/watchdog/resume-brief.sh
#
# 设计目标：**让恢复成本尽可能低。**
# 会话被掐断时上下文全丢，如果恢复要靠"重新读一遍代码、重新推理一遍思路"，
# 那么每次中断都要花掉大量 token —— 而 token 花超正是中断的原因。
# 形成一个越紧张越容易断、越断越费 token 的恶性循环。
#
# 所以这里把"该干什么"直接从 WORK_STATE.md 里抽出来打印，
# 不需要模型再分析一遍。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

line() { printf '%s\n' "────────────────────────────────────────────────────────"; }

echo
echo "  关系副驾 · 中断接手简报"
line

# ---- 1. 仓库状态 ----
branch=$(git branch --show-current 2>/dev/null || echo "?")
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
ahead=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
echo "分支 $branch ｜ 未提交改动 ${dirty} 个 ｜ 领先远端 ${ahead} 个提交"

if [ "$dirty" != "0" ]; then
  echo "  ⚠ 有未提交改动 —— 先判断它们是否已完成验证："
  git status --porcelain | head -8 | sed 's/^/      /'
fi
if [ "$ahead" != "0" ] && [ "$ahead" != "?" ]; then
  echo "  ⚠ 有 ${ahead} 个提交未推送 —— 推送前先跑 verify-fast"
fi
line

# ---- 2. WORK_STATE.md 的「进行中」段落 ----
if [ ! -f WORK_STATE.md ]; then
  echo "✗ WORK_STATE.md 不存在，无法判断进度。请先重建它。"
  exit 1
fi

echo "【进行中】"
# 只打印标题行和未勾选的清单项。
#
# 第一版把整段正文都打出来，一次 40 多行 —— 在中断恢复时这正是不该花的钱：
# 恢复本身要尽量省 token，而详细背景写在 WORK_STATE.md 里，
# 需要的时候再按标题去读那一段。这里只给"做什么"和"还差哪一步"。
awk '/^## 进行中/{f=1;next} f&&/^---/{exit} f' WORK_STATE.md \
  | grep -E '^### |^- \[ \] ' \
  | sed 's/^- \[ \]/    · 未完成 →/; s/^### /  ▸ /' \
  | head -20
line

echo "【下一步】"
# 「待办」里第一条未完成的
awk '/^## 待办/{f=1;next} f&&/^---/{exit} f' WORK_STATE.md \
  | grep -E '^[0-9]+\. ' \
  | head -3 \
  | sed 's/^/  /'
line

echo "【最后更新】$(grep -m1 -E '最后一次更新|最后更新' WORK_STATE.md | sed 's/.*：//' | sed 's/^ *//')"
line

# ---- 3. 快速健康检查（只读，不改任何东西）----
echo "【快速体检】"
if [ -f Tools/ai-proxy/package.json ]; then
  echo "  ✓ 服务端测试入口存在"
else
  echo "  ✗ 缺 Tools/ai-proxy/package.json"
fi
if [ -d RelationshipCopilot.xcodeproj ]; then
  echo "  ✓ Xcode 工程存在"
fi
if git log --oneline -1 >/dev/null 2>&1; then
  echo "  ✓ 最近提交：$(git log --oneline -1)"
fi
line
echo
echo "  建议顺序：读完上面 → 做「进行中」里第一条的最小一步 →"
echo "           bash Tools/watchdog/verify-fast.sh → 更新 WORK_STATE.md → commit"
echo
