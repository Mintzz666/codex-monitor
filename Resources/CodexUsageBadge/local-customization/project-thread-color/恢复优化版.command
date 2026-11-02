#!/bin/zsh
set -euo pipefail
support="$HOME/Library/Application Support/CodexUsageBadge"
custom="$support/local-customization/project-thread-color"
optimized="$custom/agent-folder-color.cjs"
active="$support/agent.cjs"
expected="d6e1b2d1cff2ef63964fe7b31797357d0ff25c397bdb66de351c87b1a48541db"
if [[ ! -f "$optimized" ]]; then
  print -u2 "找不到已记录的优化构建：$optimized"
  exit 1
fi
actual="$(/usr/bin/shasum -a 256 "$optimized" | /usr/bin/awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  print -u2 "优化构建哈希与当前记录不符；未覆盖活动脚本。请先更新当前优化版记录。"
  exit 1
fi
cp "$optimized" "$active.restore.tmp"
chmod 600 "$active.restore.tmp"
mv -f "$active.restore.tmp" "$active"
launchctl kickstart -k "gui/$(id -u)/com.codexusagebadge.agent"
print "已恢复固定优化版 mintzz-optimized-gpt-folder-sync-sg-sin。"
print "SHA-256：$actual"
