#!/usr/bin/env bash
set -eu

wasm="$1"
verbose="$2"
wasm_dis="$3"
manifest="$4"
out="$5"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The internal catch frame must remain named so the remove-list pin lands.
if ! grep -aqF 'agent_os_guest_call_boundary' "$wasm"; then
  fail "catch frame agent_os_guest_call_boundary is absent from the shipped wasm"
fi

# The host never drives Asyncify.
if grep -aqF 'mc_prepare_rewind' "$wasm"; then
  fail "mc_prepare_rewind present in the shipped wasm"
fi

# No host import may become a suspend-driver; only Asyncify intrinsics may change state.
viol="$out.imports"
: > "$viol"
(grep -E "\\[asyncify\\] .* is an import that can change the state" "$verbose" || true) | while IFS= read -r line; do
  name="$(printf '%s\n' "$line" | sed -E 's/^\[asyncify\] (.*) is an import that can change the state.*$/\1/')"
  case "$name" in
    asyncify_*) ;;
    *) echo "$line" >> "$viol" ;;
  esac
done
if [ -s "$viol" ]; then
  echo "FAIL: a non-Asyncify import can change state:" >&2
  cat "$viol" >&2
  exit 1
fi

wat="$out.wat"
info="$out.funcs"
tail_patterns="$out.tail_patterns"
"$wasm_dis" --enable-tail-call "$wasm" -o "$wat"

tail_count="$(grep -c 'return_call_indirect' "$wat" || true)"
if [ "$tail_count" -lt 400 ]; then
  fail "expected at least 400 wasm3 tail dispatches, found $tail_count"
fi

awk '
  /^tail_call_list:$/ { in_tail = 1; next }
  in_tail && /^  / { sub(/^  /, ""); print; next }
  in_tail && NF { exit }
' "$manifest" > "$tail_patterns"
[ -s "$tail_patterns" ] || fail "manifest tail_call_list is empty"

awk '
function emit() {
  if (name != "") print name "\t" state "\t" tail > out
}
BEGIN {
  out = ARGV[2]
  ARGV[2] = ""
}
{
  if ($0 ~ /^ \(func \$/) {
    emit()
    name = $0
    sub(/^ \(func \$/, "", name)
    sub(/[ \)].*/, "", name)
    state = 0
    tail = 0
    depth = 0
    in_func = 1
  }
  if (in_func) {
    if ($0 ~ /global\.(get|set) \$global\$1/) state = 1
    if ($0 ~ /return_call_indirect/) tail = 1
    tmp = $0
    opens = gsub(/\(/, "(", tmp)
    tmp = $0
    closes = gsub(/\)/, ")", tmp)
    depth += opens - closes
    if (depth == 0) {
      emit()
      name = ""
      in_func = 0
    }
  }
}
END {
  emit()
}
' "$wat" "$info"

lookup() {
  awk -F '\t' -v n="$1" '$1 == n { print; found = 1 } END { exit found ? 0 : 1 }' "$info"
}

check_instrumented() {
  name="$1"
  line="$(lookup "$name")" || fail "expected instrumented function is absent: $name"
  state="$(printf '%s\n' "$line" | cut -f2)"
  tail="$(printf '%s\n' "$line" | cut -f3)"
  [ "$state" = "1" ] || fail "expected $name to remain Asyncify-instrumented"
  [ "$tail" = "0" ] || fail "instrumented function $name must not contain tail dispatch"
}

tail_viol="$out.tail_violations"
if ! awk -F '\t' '
function glob_to_re(glob,    i, ch, out) {
  out = "^"
  for (i = 1; i <= length(glob); i++) {
    ch = substr(glob, i, 1)
    if (ch == "*") out = out ".*"
    else if (ch ~ /[][(){}.+?^$\\|]/) out = out "\\" ch
    else out = out ch
  }
  return out "$"
}
FNR == NR {
  if ($0 != "") {
    patterns[++npatterns] = glob_to_re($0)
    labels[npatterns] = $0
  }
  next
}
{
  for (i = 1; i <= npatterns; i++) {
    if ($1 ~ patterns[i]) {
      matched[i] = 1
      if ($2 != "0") {
        print "tail-dispatched function " $1 " is still Asyncify-instrumented"
        bad = 1
      }
      if ($3 != "1") {
        print "tail-dispatched function " $1 " has no return_call_indirect"
        bad = 1
      }
    }
  }
}
END {
  for (i = 1; i <= npatterns; i++) {
    if (!matched[i]) {
      print "tail-dispatch pattern matched no functions: " labels[i]
      bad = 1
    }
  }
  exit bad ? 1 : 0
}
' "$tail_patterns" "$info" > "$tail_viol"; then
  cat "$tail_viol" >&2
  exit 1
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  check_instrumented "$name"
done <<'INSTRUMENTED'
op_CallRawFunction
op_Call
op_CallIndirect
op_Branch
op_BranchIfPrologue_s
op_BranchIfPrologue_r
op_ContinueLoop
op_ContinueLoopIf
op_BranchIf_s
op_BranchIf_r
op_BranchTable
op_Loop
op_If_s
op_If_r
op_Entry
op_SetSlot_i32
op_CopySlot_32
op_Const32
op_i32_Load_i32_r
op_i32_Store_i32_rs
op_GetGlobal_s32
op_SetGlobal_i32
op_MemGrow
op_MemCopy
op_MemFill
op_Compile
m3_Call
m3_ConsumeFuel
agent_os_wasm3_fuel_exhausted
wasm3.raw.rawSyscall
wasm3.raw.rawPcall
wasm3.raw.rawSetThrow
wasm3.raw.suspendOrResume
INSTRUMENTED

echo ok > "$out"
