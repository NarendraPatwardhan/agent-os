#!/usr/bin/env bash
# B5 size budget gate: fail if the shipped kernel.wasm exceeds its byte ceiling.
set -euo pipefail
f="$1"
max="$2"
sz=$(wc -c < "$f")
echo "kernel.wasm: ${sz} bytes (budget: ${max})"
if [ "$sz" -gt "$max" ]; then
    echo "FAIL: over budget by $((sz - max)) bytes — optimize or raise the budget deliberately."
    exit 1
fi
echo "OK: $((max - sz)) bytes of headroom."
