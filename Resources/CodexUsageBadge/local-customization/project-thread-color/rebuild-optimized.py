#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT.parent.parent / "agent.cjs"
RESTORE_COPY = ROOT / "agent-folder-color.cjs"
MODULES = [
    ("function installProjectColors() {", "\nfunction installThreadTokens() {", "source/project-colors.js"),
    ("function installThreadTokens() {", "\nfunction isMainWindow(target) {", "source/thread-tokens-ui.js"),
    ("class ThreadTokenReader {", "\nvar AGENT_VERSION = ", "source/thread-token-reader.js"),
    ("function formatResetTime(seconds) {", "\nfunction durationLabel(", "source/reset-time-format.js"),
]

# Preserve runtime changes outside the separately maintained sidebar modules,
# including the Gemini quota badge and its shared quota data path.
bundle = RUNTIME.read_text(encoding="utf-8")
for start_marker, end_marker, source_name in MODULES:
    if bundle.count(start_marker) != 1:
        raise SystemExit(f"基线中的模块标记不唯一：{start_marker}")
    start = bundle.index(start_marker)
    end = bundle.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"找不到模块结束标记：{end_marker}")
    replacement = (ROOT / source_name).read_text(encoding="utf-8").rstrip("\n")
    bundle = bundle[:start] + replacement + bundle[end:]

for _, _, source_name in MODULES:
    replacement = (ROOT / source_name).read_text(encoding="utf-8").rstrip("\n")
    if bundle.count(replacement) != 1:
        raise SystemExit(f"构建结果没有唯一嵌入模块：{source_name}")

for output in (RUNTIME, RESTORE_COPY):
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(bundle, encoding="utf-8")
    os.chmod(temporary, output.stat().st_mode & 0o777)
    temporary.replace(output)
    print(f"已同步：{output}")
print(f"SHA-256：{hashlib.sha256(bundle.encode('utf-8')).hexdigest()}")
