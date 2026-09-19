#!/usr/bin/env bash
# Fail if any contract in src/ exceeds the EIP-170 24,576-byte runtime limit.
#
# `forge build --sizes` already exits non-zero on an oversized contract, but it reports every
# contract including test helpers and prints nothing actionable about which of *ours* is the
# problem. This narrows it to src/, names the offenders, and — because vault sizes have twice
# come within a few hundred bytes of the ceiling — also warns while a contract is merely close.
#
# Usage: script/check-sizes.sh [warn-margin]   (default warn margin: 1024 bytes)
set -euo pipefail
cd "$(dirname "$0")/.."

WARN_MARGIN="${1:-1024}"

forge build --sizes --json --skip "test/**" --skip "script/**" > /tmp/ht-sizes.json

WARN_MARGIN="$WARN_MARGIN" python3 - <<'PY'
import json, os, sys

LIMIT = 24_576
warn_margin = int(os.environ["WARN_MARGIN"])
sizes = json.load(open("/tmp/ht-sizes.json"))

# test/ and script/ are skipped at build time above, so what remains is what this repo ships.
src = {}
for name, info in sizes.items():
    runtime = info.get("runtime_size", info.get("size"))
    if runtime is None:
        continue
    src[name] = runtime

over, close = [], []
for name, size in sorted(src.items()):
    margin = LIMIT - size
    if margin < 0:
        over.append((name, size, margin))
    elif margin < warn_margin:
        close.append((name, size, margin))

for name, size, margin in close:
    print(f"::warning::{name} is {size} bytes — only {margin} under the EIP-170 limit")

if over:
    print("\nEIP-170 violation — these contracts cannot be deployed:", file=sys.stderr)
    for name, size, margin in over:
        print(f"  {name}: {size} bytes ({-margin} over the 24,576 limit)", file=sys.stderr)
    sys.exit(1)

print(f"All {len(src)} contracts within the EIP-170 limit "
      f"({len(close)} within {warn_margin} bytes of it).")
PY
