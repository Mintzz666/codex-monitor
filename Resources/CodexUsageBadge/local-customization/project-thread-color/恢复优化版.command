#!/bin/zsh
set -euo pipefail
support="$HOME/Library/Application Support/CodexUsageBadge"
custom="$support/local-customization/project-thread-color"
optimized="$custom/agent-folder-color.cjs"
active="$support/agent.cjs"
expected="0142ba6c2e23409d5ece376d8baea5136cfcaaac572c60c11ed48ae3b9d6bc69"
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
