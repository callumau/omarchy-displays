#!/bin/bash
# Tests that a swap is parked out of the way instead of briefly overlapping.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"

cat > "$tmp/bin/hyprctl" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
if args[:3] == ["-j", "monitors", "all"]:
    print(json.dumps([
        {
            "name": "A", "description": "Monitor A", "width": 2560,
            "height": 1440, "refreshRate": 59.951, "x": 0, "y": 0,
            "scale": 1, "transform": 0, "disabled": False, "focused": True
        },
        {
            "name": "B", "description": "Monitor B", "width": 2560,
            "height": 1440, "refreshRate": 59.951, "x": 2560, "y": 0,
            "scale": 1, "transform": 0, "disabled": False, "focused": False
        }
    ]))
    sys.exit(0)

if args[:1] == ["eval"]:
    with open(os.environ["EVAL_LOG"], "a") as log:
        log.write(args[1] + "\n")
    print("ok")
    sys.exit(0)

sys.exit(1)
PY
chmod +x "$tmp/bin/hyprctl"

export PATH="$tmp/bin:$PATH"
export EVAL_LOG="$tmp/eval.log"

run_case() {
  : > "$EVAL_LOG"
  python3 "$script_dir/../apply-order.py" "$1" >/dev/null
}

# A swap parks A, moves B, then puts A back.
run_case '[{"name":"A","mode":"2560x1440@59.95","position":"2560x0","scale":1,"transform":0,"disabled":false},{"name":"B","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]'
grep -q 'output = "A".*position = "5320x0"' "$EVAL_LOG"
grep -q 'output = "B".*position = "0x0"' "$EVAL_LOG"
grep -q 'output = "A".*position = "2560x0"' "$EVAL_LOG"
test "$(grep -c 'output = "A"' "$EVAL_LOG")" -eq 2

# An already-correct layout makes no live calls.
run_case '[{"name":"A","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false},{"name":"B","mode":"2560x1440@59.95","position":"2560x0","scale":1,"transform":0,"disabled":false}]'
test ! -s "$EVAL_LOG"

# A simple move applies once, without parking.
run_case '[{"name":"A","mode":"2560x1440@59.95","position":"5120x0","scale":1,"transform":0,"disabled":false},{"name":"B","mode":"2560x1440@59.95","position":"2560x0","scale":1,"transform":0,"disabled":false}]'
test "$(wc -l < "$EVAL_LOG")" -eq 1
grep -q 'output = "A".*position = "5120x0"' "$EVAL_LOG"

# Disabling a display happens before the remaining moves.
run_case '[{"name":"A","mode":"2560x1440@59.95","position":"5120x0","scale":1,"transform":0,"disabled":false},{"name":"B","disabled":true}]'
head -n 1 "$EVAL_LOG" | grep -q 'output = "B".*disabled = true'

# Invalid rules are refused before any Lua is generated.
reject_case() {
  : > "$EVAL_LOG"
  if python3 "$script_dir/../apply-order.py" "$1" >/dev/null 2>&1; then
    echo "accepted invalid rules: $1" >&2
    exit 1
  fi
  test ! -s "$EVAL_LOG"
}

reject_case '[{"name":"A\", disabled = true --","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]'
reject_case '[{"name":"A B","mode":"2560x1440@59.95","position":"0x0","scale":1,"transform":0,"disabled":false}]'
reject_case '[{"name":"A","mode":"2560x1440@59.95","position":"0x0","scale":0,"transform":0,"disabled":false}]'

echo "apply-order tests passed"
