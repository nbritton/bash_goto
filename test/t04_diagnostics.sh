#!/usr/bin/env bash
# shellcheck disable=SC2016
# (test strings quote emitted messages that contain literal ` and $)
# t04_diagnostics.sh - compile-time diagnostics: each rejected program
# must fail with exit 2 and the documented message.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..

tmp=$(mktemp -d "${TMPDIR:-/tmp}/goto-t.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# diag DESC WANT_SUBSTRING PROGRAM_TEXT
diag() {
	local desc=$1 want=$2 prog=$3
	printf '%s\n' "$prog" > "$tmp/p.sh"
	t_run bash "$root/goto.sh" -E "$tmp/p.sh"
	t_rc "$desc (exit 2)" 2 "$t_status"
	t_like "$desc (message)" "$t_err" "$want"
}

diag 'goto to a label that does not exist' \
	'goto.sh: error: goto to undefined label: nowhere' \
	$'goto nowhere\necho hi'

diag 'duplicate label' \
	'goto.sh: error: duplicate label a' \
	$'label a\nlabel a\necho hi'

diag 'label inside a loop' \
	'goto.sh: error: label inner is not at the top level of the program' \
	$'while true; do\nlabel inner\nbreak\ndone'

diag 'label placement hint mentions why' \
	'(bash cannot jump into a loop, function or block)' \
	$'while true; do\nlabel inner\nbreak\ndone'

diag 'stray break outside any loop' \
	'goto.sh: error: `break` outside any loop would hijack the trampoline' \
	$'break\necho hi'

diag 'stray continue outside any loop' \
	'goto.sh: error: `continue` outside any loop would hijack the' \
	'continue'

diag 'goto without a target' \
	'goto.sh: error: `goto` without a target' \
	$'goto\necho hi'

diag 'gosub below the top level' \
	'goto.sh: error: gosub sub must be at the top level' \
	$'while true; do\ngosub sub\nbreak\ndone\nlabel sub\nret'

diag 'syntax error in the program' \
	'goto.sh: syntax error in program:' \
	'if then fi'

diag 'gosub to an undefined label (compile-time since 1.0)' \
	'goto.sh: error: gosub to undefined label: nowhere' \
	$'gosub nowhere\necho hi'

diag 'goto inside $( ) is rejected as crossing a subshell' \
	'goto.sh: error: goto cannot cross a subshell or command substitution' \
	$'x=$(goto lbl)\nlabel lbl\necho hi'

diag 'subshell rejection explains why' \
	'(the jump would run in a child process)' \
	$'x=$(goto lbl)\nlabel lbl\necho hi'

diag 'goto inside ( ) is rejected too' \
	'goto.sh: error: goto cannot cross a subshell or command substitution' \
	$'( goto lbl )\nlabel lbl\necho hi'

diag 'unquoted computed goto target is rejected with the hint' \
	'goto.sh: error: goto target state_$state is not a valid label name' \
	$'state=S0\nlabel state_S0\ngoto state_$state'

diag 'quote-the-target hint' \
	'(quote computed targets: goto "$var")' \
	$'state=S0\nlabel state_S0\ngoto state_$state'

# --- new in 1.0.1 ---------------------------------------------------------
diag 'goto inside a backtick substitution' \
	'goto.sh: error: `goto` inside a `...` command substitution' \
	$'x=`goto lbl`\nlabel lbl\necho hi'

diag 'goto inside a function body' \
	'goto.sh: error: goto inside a function body cannot leave it' \
	$'f() { goto lbl; }\nf\nlabel lbl\necho hi'

diag 'function-local hint points at goto_trap.sh' \
	'(use goto_trap.sh if you need to jump out of a call)' \
	$'f() { goto lbl; }\nf\nlabel lbl\necho hi'

diag 'conditional gosub is rejected rather than left uncompiled' \
	'goto.sh: error: gosub must be a plain `gosub NAME`' \
	$'true && gosub sub\ngoto e\nlabel sub\nret\nlabel e\necho hi'

diag 'a label may not use the reserved namespace' \
	"goto.sh: error: label __gt_entry uses the compiler's reserved" \
	$'label __gt_entry\necho hi'

t_run bash "$root/goto.sh" -E /nonexistent-program.sh
t_rc 'a missing -E argument file exits 2' 2 "$t_status"
t_like 'a missing -E argument file is named' "$t_err" \
	'goto.sh: cannot read /nonexistent-program.sh'

t_run bash "$root/goto.sh" "$tmp"
t_rc 'a directory instead of a program exits 2' 2 "$t_status"
t_like 'a directory is diagnosed as such' "$t_err" 'is a directory'

# CLI-level errors
t_run bash "$root/goto.sh" -E
t_rc 'goto.sh -E without a file exits 2' 2 "$t_status"
t_like 'goto.sh -E without a file prints usage' "$t_err" \
	'usage: goto.sh -E prog.sh'

t_run bash "$root/goto.sh" "$tmp/does-not-exist.sh"
t_rc 'unreadable program exits 2' 2 "$t_status"
t_like 'unreadable program is named' "$t_err" 'goto.sh: cannot read'

t_done
