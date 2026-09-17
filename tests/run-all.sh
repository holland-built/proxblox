#!/usr/bin/env bash
# Every test, in order. Nothing here touches Proxmox or the Infoblox tenant.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fail=0
for t in "$HERE"/test_*.py; do
  echo "== $(basename "$t") =="
  python3 "$t" || fail=1
  echo
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  shellcheck -S warning "$HERE/../scripts"/*.sh "$HERE/../niosx" && echo "clean"
  echo
else
  echo "== shellcheck == (not installed — skipped)"
  echo
fi

if [ "$fail" = 0 ]; then echo "ALL GREEN"; else echo "FAILURES ABOVE"; fi
exit "$fail"
