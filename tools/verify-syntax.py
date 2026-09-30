# -*- coding: utf-8 -*-
"""Parse every module in the repository. No imports, no dependencies.

Deliberately uses ast.parse rather than importing: importing device.py pulls in
comtypes and touches COM, which is exactly what should not happen on a machine
without an audio stack. Parsing catches the syntax errors that actually break a
push, and nothing else.

Run:  python tools/verify-syntax.py     (exit 0 = all modules parse)
"""
import ast
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

failures = []
checked = 0

for path in sorted(ROOT.rglob("*.py")):
    parts = set(path.relative_to(ROOT).parts)
    if parts & {".venv", "__pycache__", ".git", ".playwright-cli", "node_modules"}:
        continue
    try:
        source = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        failures.append("%s: not valid UTF-8 (%s)" % (path.relative_to(ROOT), exc))
        continue
    try:
        ast.parse(source, str(path))
        checked += 1
    except SyntaxError as exc:
        failures.append("%s:%s: %s" % (path.relative_to(ROOT), exc.lineno, exc.msg))

print("parsed %d modules" % checked)
for line in failures:
    print("  FAIL %s" % line)

if failures:
    print("\nFAIL - %d of %d modules did not parse" % (len(failures), checked + len(failures)))
    sys.exit(1)
print("PASS")