#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit). Exit 2 = block; stderr goes to Claude.
set -u

if ! command -v python3 >/dev/null 2>&1; then
  echo "BLOCKED: policy hook requires python3 and cannot safely inspect this edit." >&2
  exit 2
fi

HOOK_INPUT="$(cat)"
HOOK_INPUT="$HOOK_INPUT" python3 <<'PY'
import json
import os
from collections import Counter
from pathlib import Path
import re
import sys

try:
    data = json.loads(os.environ["HOOK_INPUT"])
except (KeyError, json.JSONDecodeError) as error:
    sys.stderr.write(f"BLOCKED: invalid policy-hook input: {error}\n")
    sys.exit(2)

tool_input = data.get("tool_input", {}) or {}
path = tool_input.get("file_path", "") or ""
if not path:
    sys.exit(0)

normalized_path = path.replace("\\", "/")
policy_path = re.compile(
    r"(^|/)\.(?:claude|codex|agents)/|(^|/)AGENTS\.md$|(^|/)\.github/workflows/"
)
if policy_path.search(normalized_path):
    sys.stderr.write(
        f"BLOCKED: '{path}' is a policy/CI file. Changes here require a human.\n"
    )
    sys.exit(2)

test_path = re.compile(
    r"(^|/)(tests?|__tests__)(/|$)"
    r"|(^|/)(test_[^/]+|[^/]+_(test|tests))\.(py|go)$"
    r"|(^|/)[^/]+\.(test|spec)\.[jt]sx?$"
    r"|(^|/)(test[^/]*|[^/]+tests)\.swift$"
    r"|\.xctestplan$",
    re.IGNORECASE,
)
swift_test_bundle_path = re.compile(r"(^|/)[^/]*Tests(/|$)")
if not (test_path.search(normalized_path) or swift_test_bundle_path.search(normalized_path)):
    sys.exit(0)

edits = tool_input.get("edits") or [{
    "old_string": tool_input.get("old_str") or tool_input.get("old_string") or "",
    "new_string": tool_input.get("new_str") or tool_input.get("new_string") or tool_input.get("content", ""),
}]

# Write supplies the complete new file but no old_string. Read the existing test
# before the tool runs so whole-file rewrites cannot bypass assertion removal.
if "content" in tool_input and edits[0].get("old_string", "") == "":
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = Path(os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())) / candidate
    if candidate.exists():
        edits[0]["old_string"] = candidate.read_text(encoding="utf-8")

skip_pattern = re.compile(
    r"XCTSkip|\bxit\s*\(|\bxdescribe\s*\(|\.skip\s*\(|@Disabled|@Ignore\b|it\.todo|continue-on-error"
)
swift_testing_disabled_pattern = re.compile(
    r"@(?:Test|Suite)\b(?:(?!\b(?:func|struct|class|actor|enum)\b).){0,1000}?\.disabled\s*\(",
    re.DOTALL,
)
assert_pattern = re.compile(r"XCTAssert|#(?:expect|require)|XCTFail|\bexpect\s*\(|\bassert(?:\b|[A-Z_])")
declaration_pattern = re.compile(
    r"\b(?:func|def|function|class|struct|actor|enum)\s+([A-Za-z_]\w*)"
)

def skip_sites(value: str) -> Counter[tuple[str, str]]:
    sites = Counter()
    matches = [*skip_pattern.finditer(value), *swift_testing_disabled_pattern.finditer(value)]
    declarations = list(declaration_pattern.finditer(value))
    for match in matches:
        marker = re.sub(r"\s+", "", match.group(0)).lower()
        previous = [item for item in declarations if item.end() <= match.start()]
        following = [item for item in declarations if item.start() >= match.end()]
        identity = ""
        prefer_following = marker.startswith("@") or ".skip(" in marker or "it.todo" in marker
        if prefer_following and following and following[0].start() - match.end() <= 1000:
            identity = following[0].group(1)
        elif previous and match.start() - previous[-1].end() <= 1000:
            identity = previous[-1].group(1)
        elif following and following[0].start() - match.end() <= 1000:
            identity = following[0].group(1)
        if not identity:
            line_start = value.rfind("\n", 0, match.start()) + 1
            line_end = value.find("\n", match.end())
            if line_end < 0:
                line_end = len(value)
            identity = re.sub(r"\s+", " ", value[line_start:line_end].strip())
        sites[(marker, identity)] += 1
    return sites

def assertion_count(value: str) -> int:
    return len(assert_pattern.findall(value))

for edit in edits:
    old = edit.get("old_string", "") or ""
    new = edit.get("new_string", "") or ""
    if skip_sites(new) - skip_sites(old):
        sys.stderr.write(
            "BLOCKED: this edit introduces a skip/disable marker into a test file.\n"
            "Fix the implementation; if the test is wrong, leave it for a human.\n"
        )
        sys.exit(2)
    if assertion_count(new) < assertion_count(old):
        sys.stderr.write(
            "BLOCKED: this edit removes assertions from a test without replacing them.\n"
            "Weakening tests to get green is not allowed.\n"
        )
        sys.exit(2)
sys.exit(0)
PY
status=$?
if [[ $status -ne 0 ]]; then
  if [[ $status -ne 2 ]]; then
    echo "BLOCKED: policy hook failed unexpectedly; refusing to fail open." >&2
  fi
  exit 2
fi
