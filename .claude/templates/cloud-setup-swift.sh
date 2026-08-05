#!/usr/bin/env bash
# Environment SETUP SCRIPT for Swift repos — paste into the routine's cloud
# environment config. The SAME environment's Network access must include
# these custom allowed domains:
#   download.swift.org
#   archive.ubuntu.com
#   security.ubuntu.com
#
# Notes:
# - The egress proxy answers blocked hosts with 403 pages, which apt
#   misreports as "repository is no longer signed". 403 = allowlist problem.
# - The base image ships extra apt sources (PPAs, Docker) that are NOT
#   allowlisted and never will be; we remove them so apt-get update can
#   succeed on the Ubuntu mirrors alone.
# - Setup scripts are cached, so the toolchain cost is paid on cache
#   misses, not every run.
set -uo pipefail

# --- Sandbox-only permissions -------------------------------------------
# This script runs ONLY in the disposable cloud VM, so user-scope settings
# written here never touch a local machine. Broad allow here + the repo's
# committed deny-hooks + branch protection = unattended runs that never
# stall on an approval prompt, while local sessions keep prompting.
mkdir -p ~/.claude
merge_sandbox_permissions() {
  python3 - "$HOME/.claude/settings.json" <<'PY'
import json
import os
from pathlib import Path
import sys
import tempfile

path = Path(sys.argv[1])
try:
    settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except json.JSONDecodeError as error:
    raise SystemExit(f"Refusing to replace invalid {path}: {error}")
if not isinstance(settings, dict):
    raise SystemExit(f"Refusing to replace non-object settings in {path}")
permissions = settings.setdefault("permissions", {})
if not isinstance(permissions, dict):
    raise SystemExit(f"Expected permissions to be an object in {path}")
allowed = permissions.setdefault("allow", [])
if not isinstance(allowed, list):
    raise SystemExit(f"Expected permissions.allow to be an array in {path}")
for permission in ("Bash", "Edit", "Write", "MultiEdit"):
    if permission not in allowed:
        allowed.append(permission)
fd, temporary = tempfile.mkstemp(prefix=".settings.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(settings, stream, indent=2)
        stream.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}
if ! merge_sandbox_permissions; then
  echo "FATAL: could not merge sandbox permissions; refusing to continue with unattended setup" >&2
  exit 1
fi
echo "==> Sandbox permissions merged (user scope, VM-only)"

# Version resolution — minimum-bound semantics:
#   1. If the cloned repo has a .swift-version file (repo root), use it.
#      Keep that file updated in the same PR that bumps a dependency whose
#      swift-tools-version rises (you can't derive the true bound here:
#      it's the max across the dependency graph, unknowable pre-resolution).
#   2. Otherwise fall back to DEFAULT_SWIFT_VERSION below.
# A cached toolchain is kept if it's >= the required version, replaced if older.
DEFAULT_SWIFT_VERSION="6.3.3"
SWIFT_VERSION="$DEFAULT_SWIFT_VERSION"
for f in ./.swift-version */.swift-version; do
  if [[ -f "$f" ]]; then
    SWIFT_VERSION="$(tr -d '[:space:]' < "$f")"
    echo "==> Required Swift >= $SWIFT_VERSION (from $f)"
    break
  fi
done
UBUNTU="ubuntu24.04"; UBUNTU_DIR="ubuntu2404"

# Minimum-bound idempotency: keep a cached toolchain that satisfies the
# bound (>= required), replace one that doesn't.
version_lt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }
if command -v swift >/dev/null 2>&1; then
  CURRENT="$(swift --version 2>&1 | grep -oE 'Swift version [0-9.]+' | awk '{print $3}')"
  if version_lt "$CURRENT" "$SWIFT_VERSION"; then
    echo "==> Cached swift $CURRENT < required $SWIFT_VERSION — replacing"
    rm -rf /opt/swift-*-RELEASE-* 2>/dev/null || true
  else
    echo "swift $CURRENT already satisfies >= $SWIFT_VERSION"; exit 0
  fi
fi

echo "==> Pruning apt sources that are not on the egress allowlist"
mkdir -p /etc/apt/sources.list.d.disabled
mv /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d.disabled/ 2>/dev/null || true
mv /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d.disabled/ 2>/dev/null || true
# keep only the main ubuntu sources (sources.list or ubuntu.sources)
if [[ -f /etc/apt/sources.list.d.disabled/ubuntu.sources ]]; then
  mv /etc/apt/sources.list.d.disabled/ubuntu.sources /etc/apt/sources.list.d/
fi

echo "==> Installing Swift runtime dependencies"
export DEBIAN_FRONTEND=noninteractive
if apt-get update -qq; then
  apt-get install -y -qq binutils libc6-dev libcurl4-openssl-dev libedit2 \
    libgcc-13-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libz3-dev pkg-config tzdata zlib1g-dev curl || {
      echo "WARN: some dependency installs failed; attempting toolchain anyway" >&2; }
else
  echo "WARN: apt-get update failed (are archive.ubuntu.com + security.ubuntu.com allowlisted?)." >&2
  echo "      Attempting toolchain install with the image's existing libraries." >&2
fi

echo "==> Downloading Swift toolchain (cached across sessions)"
URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${UBUNTU_DIR}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${UBUNTU}.tar.gz"
if ! curl -fsSL "$URL" | tar xz -C /opt; then
  echo "FATAL: could not fetch the toolchain — is download.swift.org in this environment's allowed domains?" >&2
  exit 1
fi
ln -sf /opt/swift-${SWIFT_VERSION}-RELEASE-${UBUNTU}/usr/bin/* /usr/local/bin/

if swift --version; then
  echo "==> Swift ready"
else
  echo "FATAL: swift installed but won't run — likely missing shared libraries." >&2
  echo "Missing libs:" >&2
  ldd "/opt/swift-${SWIFT_VERSION}-RELEASE-${UBUNTU}/usr/bin/swift" 2>/dev/null | grep "not found" >&2 || true
  exit 1
fi
