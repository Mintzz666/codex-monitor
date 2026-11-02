#!/bin/zsh
set -euo pipefail
support="$HOME/Library/Application Support/CodexUsageBadge"
backup="$support/local-customization/project-thread-color/backup-v0.9.1/agent.cjs"
active="$support/agent.cjs"
if [[ ! -f "$backup" ]]; then
  print -u2 "找不到原版备份：$backup"
  exit 1
fi
cp "$backup" "$active.rollback.tmp"
chmod 600 "$active.rollback.tmp"
mv -f "$active.rollback.tmp" "$active"
launchctl kickstart -k "gui/$(id -u)/com.codexusagebadge.agent"
print "已恢复 Codex Usage Badge v0.9.1 原版，并重启后台。"
