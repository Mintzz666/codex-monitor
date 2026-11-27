#!/bin/zsh
set -euo pipefail
support="$HOME/Library/Application Support/CodexUsageBadge"
custom="$support/local-customization/project-thread-color"
optimized="$custom/agent-folder-color.cjs"
active="$support/agent.cjs"
expected="8cd9c71f92a204878d0b069f519f4e6495c234febebc20d1c973c08e925eeff7"
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
print "已恢复固定优化版 mintzz-gemini-quota。"
print "SHA-256：$actual"
