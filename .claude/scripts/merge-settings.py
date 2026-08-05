#!/usr/bin/env python3
"""Merge loop-owned Claude hooks while preserving all unrelated settings."""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from typing import Any


OWNED_SCRIPT_NAMES = {"guard-bash.sh", "protect-files.sh"}


def load_object(path: Path, *, missing_ok: bool = False) -> dict[str, Any]:
    if missing_ok and not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"merge-settings: cannot read valid JSON from {path}: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"merge-settings: expected a JSON object in {path}")
    return value


def is_owned_hook(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    command = value.get("command")
    if not isinstance(command, str):
        return False
    normalized = command.replace('\\"', '"').rstrip('"')
    return any(normalized.endswith(f"/.claude/scripts/{name}") for name in OWNED_SCRIPT_NAMES)


def merge(existing: dict[str, Any], template: dict[str, Any]) -> dict[str, Any]:
    hooks = existing.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise SystemExit("merge-settings: existing 'hooks' value must be an object")

    existing_pre = hooks.get("PreToolUse", [])
    if not isinstance(existing_pre, list):
        raise SystemExit("merge-settings: existing 'hooks.PreToolUse' value must be an array")

    template_hooks = template.get("hooks")
    if not isinstance(template_hooks, dict) or not isinstance(template_hooks.get("PreToolUse"), list):
        raise SystemExit("merge-settings: template must contain a hooks.PreToolUse array")

    preserved: list[Any] = []
    for entry in existing_pre:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            preserved.append(entry)
            continue
        remaining = [hook for hook in entry["hooks"] if not is_owned_hook(hook)]
        if remaining:
            copied = dict(entry)
            copied["hooks"] = remaining
            preserved.append(copied)

    hooks["PreToolUse"] = preserved + template_hooks["PreToolUse"]
    return existing


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: merge-settings.py TARGET TEMPLATE")
    target, template = map(Path, sys.argv[1:])
    atomic_write(target, merge(load_object(target, missing_ok=True), load_object(template)))


if __name__ == "__main__":
    main()
