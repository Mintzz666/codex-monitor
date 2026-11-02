#!/bin/zsh
set -euo pipefail

app="/Applications/ChatGPT.app"
node="$app/Contents/Resources/cua_node/bin/node"
manager="$HOME/Library/Application Support/CodexUsageBadge/manage.cjs"

if [[ ! -x "$node" ]]; then
  print -u2 "未找到 ChatGPT 自带的 Node.js：$node"
  exit 1
fi
if [[ ! -f "$manager" ]]; then
  print -u2 "未找到 Codex Usage Badge 启动管理程序：$manager"
  exit 1
fi

export CODEX_BADGE_APP="$app"
exec "$node" "$manager" launch
