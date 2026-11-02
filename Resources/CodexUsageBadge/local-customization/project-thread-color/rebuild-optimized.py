#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BASE = ROOT / "backup-before-gpt-project-association" / "agent.cjs"
OUTPUT = ROOT / "agent-folder-color.cjs"
EXPECTED_BASE_SHA256 = "9ade7f6e7388c4408551fcf843ecb9a8691e8223ba9334619a5148071cc549c6"
MODULES = [
    ("function installProjectColors() {", "\nfunction installThreadTokens() {", "source/project-colors.js"),
    ("function installThreadTokens() {", "\nfunction isMainWindow(target) {", "source/thread-tokens-ui.js"),
    ("class ThreadTokenReader {", "\nvar AGENT_VERSION = ", "source/thread-token-reader.js"),
    ("function formatResetTime(seconds) {", "\nfunction durationLabel(", "source/reset-time-format.js"),
]

base_bytes = BASE.read_bytes()
base_sha256 = hashlib.sha256(base_bytes).hexdigest()
if base_sha256 != EXPECTED_BASE_SHA256:
    raise SystemExit(f"基线哈希不匹配：{base_sha256}")
bundle = base_bytes.decode("utf-8")
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

temporary = OUTPUT.with_suffix(OUTPUT.suffix + ".tmp")
temporary.write_text(bundle, encoding="utf-8")
os.chmod(temporary, 0o600)
temporary.replace(OUTPUT)
print(f"已从固定基线构建：{OUTPUT}")
print(f"SHA-256：{hashlib.sha256(OUTPUT.read_bytes()).hexdigest()}")
