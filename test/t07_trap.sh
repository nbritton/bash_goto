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
printf '#!/usr/bin/env bash\nsource "%s"\necho start\ngoto nope\necho no\n' \
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
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/loop.sh"
printf 'i=0\nkept=preserved\nlabel top\n(( i++ ))\n' >> "$tmp/loop.sh"
printf '(( i < 3 )) && goto top\necho "i=$i kept=$kept"\n' \
	>> "$tmp/loop.sh"
t_run bash "$tmp/loop.sh"
t_rc 'backward-jump loop exits 0' 0 "$t_status"
t_is 'loop counter and state survive the jumps' "$t_out" \
	'i=3 kept=preserved'

# --- comment-label sugar --------------------------------------------------
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/sugar.sh"
printf 'goto a\necho no\n# label a\necho A\ngoto b\necho no\n' \
	>> "$tmp/sugar.sh"
printf '#: b\necho B\n' >> "$tmp/sugar.sh"
t_run bash "$tmp/sugar.sh"
t_is 'comment labels work in the trap runtime too' "$t_out" $'A\nB'

# --- subshell guard (new in 1.0) ------------------------------------------
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/sub.sh"
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
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/fn.sh"
printf 'f() { g; echo no-f; }\ng() { goto out; echo no-g; }\nf\n' \
	>> "$tmp/fn.sh"
printf 'echo no-main\nlabel out\necho escaped\n' >> "$tmp/fn.sh"
t_run bash "$tmp/fn.sh"
t_rc 'longjmp out of nested functions exits 0' 0 "$t_status"
t_is 'longjmp unwinds both frames' "$t_out" 'escaped'

# --- exit status propagates (new in 1.0.1) --------------------------------
printf '#!/usr/bin/env bash\nsource "%s"\necho hi\nfalse\n' "$trap_sh" \
	> "$tmp/rc1.sh"
t_run bash "$tmp/rc1.sh"
t_rc 'a failing final command exits nonzero' 1 "$t_status"

printf '#!/usr/bin/env bash\nsource "%s"\necho hi\ntrue\n' "$trap_sh" \
	> "$tmp/rc0.sh"
t_run bash "$tmp/rc0.sh"
t_rc 'a succeeding final command exits 0' 0 "$t_status"

printf '#!/usr/bin/env bash\nsource "%s"\nexit 7\n' "$trap_sh" \
	> "$tmp/rc7.sh"
t_run bash "$tmp/rc7.sh"
t_rc 'an explicit exit still wins' 7 "$t_status"

printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/rcj.sh"
printf 'goto L\nlabel L\nfalse\n' >> "$tmp/rcj.sh"
t_run bash "$tmp/rcj.sh"
t_rc 'a status after a jump propagates too' 1 "$t_status"

# --- the program's argv reaches the program (new in 1.0.1) ----------------
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/args.sh"
printf 'echo "n=$# a=$1 b=$2"\ngoto L\nlabel L\necho "after=$1"\n' \
	>> "$tmp/args.sh"
t_run bash "$tmp/args.sh" alpha 'b c'
t_is 'positional parameters reach the program' "$t_out" \
	$'n=2 a=alpha b=b c\nafter=alpha'

# --- errexit survives a jump (new in 1.0.1) -------------------------------
printf '#!/usr/bin/env bash\nsource "%s"\nset -e\n' "$trap_sh" \
	> "$tmp/ee.sh"
printf 'echo A\ngoto L\necho NEVER\nlabel L\necho B\n' >> "$tmp/ee.sh"
t_run bash "$tmp/ee.sh"
t_rc 'a goto under set -e is not fatal' 0 "$t_status"
t_is 'a goto under set -e still jumps' "$t_out" $'A\nB'

printf '#!/usr/bin/env bash\nsource "%s"\nset -e\n' "$trap_sh" \
	> "$tmp/ee2.sh"
printf 'echo A\ngoto L\nlabel L\nfalse\necho NEVER\n' >> "$tmp/ee2.sh"
t_run bash "$tmp/ee2.sh"
t_rc 'set -e still exits on a real failure after a jump' 1 "$t_status"
t_is 'set -e stops the program where it should' "$t_out" 'A'

# --- a stolen DEBUG trap is fatal, not silent (new in 1.0.1) --------------
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/dbg.sh"
printf 'echo A\ntrap "true" DEBUG\ngoto b\necho NO\nlabel b\necho B\n' \
	>> "$tmp/dbg.sh"
t_run bash "$tmp/dbg.sh"
if (( t_status != 0 )); then
	t_ok "losing the DEBUG trap is fatal (got $t_status)"
else
	t_not_ok 'losing the DEBUG trap is fatal'
fi
t_like 'losing the DEBUG trap says what happened' "$t_err" \
	'the DEBUG trap this runtime needs was replaced or cleared'

# --- a label inside a heredoc is not a jump target (new in 1.0.1) ---------
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" > "$tmp/hd.sh"
printf 'i=0\nlabel loop\n(( i++ ))\ncat <<DOC\nlabel loop\nDOC\n' \
	>> "$tmp/hd.sh"
printf '(( i < 3 )) && goto loop\necho "done i=$i"\n' >> "$tmp/hd.sh"
t_run bash "$tmp/hd.sh"
t_rc 'a label inside a heredoc does not capture the jump' 0 "$t_status"
t_is 'the heredoc body is printed, the real label is used' "$t_out" \
	$'label loop\nlabel loop\nlabel loop\ndone i=3'

# quoted `<<` text must not hide labels from the indexer
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" \
	> "$tmp/qhd.sh"
printf 'echo "<<EOF"\ngoto L\n#: L\necho landed\n' >> "$tmp/qhd.sh"
t_run bash "$tmp/qhd.sh"
t_is 'quoted << text is not a heredoc opener' "$t_out" \
	$'<<EOF\nlanded'

printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" \
	> "$tmp/nqhd.sh"
printf 'echo "$(echo "<<EOF")"\ngoto L\n#: L\necho landed\n' \
	>> "$tmp/nqhd.sh"
t_run bash "$tmp/nqhd.sh"
t_is 'nested quoted << text is not a heredoc opener' "$t_out" \
	$'<<EOF\nlanded'

# multiple and quoted heredoc delimiters are indexed in source order
printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" \
	> "$tmp/mhd.sh"
printf 'cat <<A <<B\nfirst\nA\ngoto NOPE\nlabel PHANTOM\n' \
	>> "$tmp/mhd.sh"
printf 'second\nB\ngoto REAL\necho NEVER\nlabel REAL\necho landed\n' \
	>> "$tmp/mhd.sh"
t_run bash "$tmp/mhd.sh"
t_rc 'multiple heredocs do not expose false labels' 0 "$t_status"
t_is 'multiple heredoc bodies stay data in the trap runtime' "$t_out" \
	$'goto NOPE\nlabel PHANTOM\nsecond\nlanded'

printf '#!/usr/bin/env bash\nsource "%s"\n' "$trap_sh" \
	> "$tmp/qdelim.sh"
printf "cat <<'END DOC'\ngoto NOPE\nlabel PHANTOM\nEND DOC\n" \
	>> "$tmp/qdelim.sh"
printf 'goto REAL\nlabel REAL\necho landed\n' >> "$tmp/qdelim.sh"
t_run bash "$tmp/qdelim.sh"
t_is 'quoted heredoc delimiters may contain spaces' "$t_out" \
	$'goto NOPE\nlabel PHANTOM\nlanded'

# ambiguous and malformed targets fail before arming a longjmp
printf '#!/usr/bin/env bash\nsource "%s"\nlabel L\nlabel L\n' \
	"$trap_sh" > "$tmp/dup.sh"
t_run bash "$tmp/dup.sh"
t_rc 'duplicate trap-runtime labels exit 2' 2 "$t_status"
t_like 'duplicate trap-runtime labels are named' "$t_err" \
	'goto_trap.sh: duplicate label: L'

printf '#!/usr/bin/env bash\nsource "%s"\ngoto\n' "$trap_sh" \
	> "$tmp/noarg.sh"
t_run bash "$tmp/noarg.sh"
t_rc 'goto without a trap-runtime target exits 2' 2 "$t_status"
t_like 'goto without a trap-runtime target says so' "$t_err" \
	'goto: missing label'

printf '#!/usr/bin/env bash\nsource "%s"\nlabel L\ngoto L extra\n' \
	"$trap_sh" > "$tmp/extra.sh"
t_run bash "$tmp/extra.sh"
t_rc 'goto with an extra trap-runtime target exits 2' 2 "$t_status"
t_like 'goto with an extra trap-runtime target says so' "$t_err" \
	'goto: expected exactly one label'

t_done
