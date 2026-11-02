#!/bin/zsh
set -euo pipefail
support="$HOME/Library/Application Support/CodexUsageBadge"
custom="$support/local-customization/project-thread-color"
previous="$custom/backup-before-gpt-project-association/agent.cjs"
active="$support/agent.cjs"
expected="9ade7f6e7388c4408551fcf843ecb9a8691e8223ba9334619a5148071cc549c6"
if [[ ! -f "$previous" ]]; then
  print -u2 "找不到 GPT 文件夹映射修复前的优化版：$previous"
  exit 1
fi
actual="$(/usr/bin/shasum -a 256 "$previous" | /usr/bin/awk '{print $1}')"
if [[ "$actual" != "$expected" ]]; then
  print -u2 "回退文件哈希与固定基线不符；未覆盖活动脚本。"
  exit 1
fi
cp "$previous" "$active.restore.tmp"
chmod 600 "$active.restore.tmp"
mv -f "$active.restore.tmp" "$active"
launchctl kickstart -k "gui/$(id -u)/com.codexusagebadge.agent"
print "已回退到 GPT 文件夹映射修复前的优化版。"
print "SHA-256：$actual"
