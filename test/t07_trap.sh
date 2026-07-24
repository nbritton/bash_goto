#!/usr/bin/env bash
# shellcheck disable=SC2016
# (generated programs quote $ expansions that must expand at their run
#  time, not while being written)
# t07_trap.sh - functional tests for the DEBUG-trap runtime, goto_trap.sh.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
rootabs=$(cd "$root" && pwd) || exit 1

tmp=$(mktemp -d "${TMPDIR:-/tmp}/goto-t.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# make TRAP a resolvable path for generated programs
trap_sh=$rootabs/goto_trap.sh

# --- the longjmp example (also golden-checked in t05) ---------------------
ex06=("$root/examples/06_"*.sh)
t_run bash "${ex06[0]}"
t_rc 'example 06 exits 0' 0 "$t_status"
t_diff 'example 06 output matches golden' 'golden/06.out' "$t_out"

# --- unknown label --------------------------------------------------------
printf '#!/usr/bin/env bash\nsource %s\necho start\ngoto nope\necho no\n' \
	"$trap_sh" > "$tmp/unknown.sh"
t_run bash "$tmp/unknown.sh"
t_rc 'goto to unknown label exits 2' 2 "$t_status"
t_like 'goto to unknown label names it' "$t_err" \
	'goto: no such label: nope'
t_is 'program stops at the bad goto' "$t_out" 'start'

# --- must be sourced from a script ----------------------------------------
t_run bash -c "source '$trap_sh'"
t_rc 'sourcing outside a script exits 2' 2 "$t_status"
t_like 'sourcing outside a script says so' "$t_err" \
	'goto_trap.sh: must be sourced from a script'

# --- backward jumps keep shell state --------------------------------------
printf '#!/usr/bin/env bash\nsource %s\n' "$trap_sh" > "$tmp/loop.sh"
printf 'i=0\nkept=preserved\nlabel top\n(( i++ ))\n' >> "$tmp/loop.sh"
printf '(( i < 3 )) && goto top\necho "i=$i kept=$kept"\n' \
	>> "$tmp/loop.sh"
t_run bash "$tmp/loop.sh"
t_rc 'backward-jump loop exits 0' 0 "$t_status"
t_is 'loop counter and state survive the jumps' "$t_out" \
	'i=3 kept=preserved'

# --- comment-label sugar --------------------------------------------------
printf '#!/usr/bin/env bash\nsource %s\n' "$trap_sh" > "$tmp/sugar.sh"
printf 'goto a\necho no\n# label a\necho A\ngoto b\necho no\n' \
	>> "$tmp/sugar.sh"
printf '#: b\necho B\n' >> "$tmp/sugar.sh"
t_run bash "$tmp/sugar.sh"
t_is 'comment labels work in the trap runtime too' "$t_out" $'A\nB'

# --- subshell guard (new in 1.0) ------------------------------------------
printf '#!/usr/bin/env bash\nsource %s\n' "$trap_sh" > "$tmp/sub.sh"
printf 'echo start\nx=$(goto later)\necho no\nlabel later\necho no2\n' \
	>> "$tmp/sub.sh"
t_run bash "$tmp/sub.sh"
if (( t_status != 0 )); then
	t_ok "goto in a command substitution dies nonzero (got $t_status)"
else
	t_not_ok 'goto in a command substitution dies nonzero'
fi
t_like 'subshell guard names the goto' "$t_err" \
	'goto: fatal: `goto later` executed in a subshell or pipeline'
t_is 'subshell guard fires before any jump' "$t_out" 'start'

t_run env GOTO_STRICT=0 bash "$tmp/sub.sh"
t_rc 'GOTO_STRICT=0 restores the old silent-loss behavior' 0 "$t_status"

# --- the one thing goto.sh cannot do: longjmp out of a function -----------
printf '#!/usr/bin/env bash\nsource %s\n' "$trap_sh" > "$tmp/fn.sh"
printf 'f() { g; echo no-f; }\ng() { goto out; echo no-g; }\nf\n' \
	>> "$tmp/fn.sh"
printf 'echo no-main\nlabel out\necho escaped\n' >> "$tmp/fn.sh"
t_run bash "$tmp/fn.sh"
t_rc 'longjmp out of nested functions exits 0' 0 "$t_status"
t_is 'longjmp unwinds both frames' "$t_out" 'escaped'

t_done
