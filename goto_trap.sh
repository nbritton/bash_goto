#!/usr/bin/env bash
# goto_trap.sh - GOTO for bash with no compiler pass at all.
#
# Different mechanism from goto.sh.  Two bash facts do all the work:
#
#   1. TAIL-EVAL TRAMPOLINE.  "Jump to label L" == "evaluate the program text
#      from L's line to EOF".  A while-loop around that eval is the
#      trampoline; each jump is a tail call into a fresh eval, so the eval
#      stack never grows no matter how many jumps happen.  Only label *line
#      numbers* are needed, so there is no parsing, no segmentation, no
#      nesting analysis.
#
#   2. DEBUG-TRAP LONGJMP.  From the bash manual: with `shopt -s extdebug`,
#      if the DEBUG trap returns 2 while the shell is in a subroutine, the
#      shell *simulates a return*.  The trap fires before every command, so a
#      pending jump unwinds one frame per command until it reaches the
#      trampoline.  That is a real longjmp: it escapes nested loops, `case`,
#      `if`, `{ ; }`, and even user functions the program called -- which the
#      compiled `continue N` in goto.sh cannot do.
#
# Cost: the DEBUG trap runs before every single command, so this is slow, and
# it burns the DEBUG trap and `extdebug` for the whole program.  goto.sh is
# the one to use in anger (insofar as that phrase applies here); this one is
# the proof that you don't actually need the compiler.
#
# shellcheck disable=SC2317,SC2016
# (SC2016: the fatal-goto message quotes a literal `goto %s` on purpose.)
# (label/goto/__gt_dbg look unreachable to static analysis: they are
#  called by the sourcing program and by the DEBUG trap.)
#
# Usage:  source goto_trap.sh   as the first line of your program.
#         label NAME / goto NAME, same surface syntax as goto.sh.
#
# Environment:  GOTO_STRICT=0 disables the runtime subshell guard, as in
#               goto.sh.

# sourced by zsh or another non-bash shell?  refuse politely: an `exit`
# here would close the user's interactive shell (macOS defaults to zsh)
if [[ -z ${BASH_VERSION-} ]]; then
	printf 'goto_trap.sh: this is a bash tool; source it from the\n' >&2
	printf 'first line of a bash script\n' >&2
	return 2 2>/dev/null
	exit 2
fi

if (( BASH_VERSINFO[0] < 5 )); then
	printf 'goto_trap.sh: bash >= 5 required (this is bash %s)\n' \
	    "$BASH_VERSION" >&2
	exit 2
fi

set -T                            # DEBUG trap is inherited by functions
shopt -s extdebug expand_aliases

__GT_SRC=${BASH_SOURCE[1]:-}
__GT_BASE=$(( ${BASH_LINENO[0]:-0} + 1 ))
if [[ ! -r $__GT_SRC ]]; then
	echo 'goto_trap.sh: must be sourced from a script' >&2
	exit 2
fi

declare -gA __GT_LBL=()
__GT_PC=''
__GT_SHELL=$BASHPID

# pass 0: index the labels by line number, entirely in bash -- this loop is
# the whole "compiler"
mapfile -t __GT_LINES < "$__GT_SRC"
__gt_lbl_re='^[[:space:]]*(label|#[[:space:]]*label|#:)[[:space:]]+'
__gt_lbl_re+='([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$'
for (( __gt_i = __GT_BASE - 1; __gt_i < ${#__GT_LINES[@]}; __gt_i++ )); do
	[[ ${__GT_LINES[__gt_i]} =~ $__gt_lbl_re ]] || continue
	__GT_LBL[${BASH_REMATCH[2]}]=$(( __gt_i + 1 ))
done
unset -v __gt_i __gt_lbl_re

label() { :; }

# arm the longjmp
goto() {
	# a goto in a subshell or pipeline can never reach the trampoline;
	# without this guard the jump would just be silently lost
	if [[ ${GOTO_STRICT-1} != 0 && $BASHPID != "$__GT_SHELL" ]]; then
		printf 'goto: fatal: `goto %s` executed in a subshell' \
		    "$1" >&2
		printf ' or pipeline (pid %s != %s)\n' \
		    "$BASHPID" "$__GT_SHELL" >&2
		kill -s TERM "$__GT_SHELL" 2>/dev/null
		exit 70
	fi
	if [[ -z ${__GT_LBL[$1]+x} ]]; then
		printf 'goto: no such label: %s\n' "$1" >&2
		exit 2
	fi
	__GT_PC=$1
}

# return 2 => bash simulates `return`, one frame per command, until we are
# back in __gt_run (which does the bookkeeping and must not be unwound).
__gt_dbg() {
	[[ -n $__GT_PC && ${FUNCNAME[1]} != __gt_run ]] && return 2
	return 0
}

# tail call: evaluate the program text from line $1 to EOF
__gt_step() {
	local __gt_text
	printf -v __gt_text '%s\n' "${__GT_LINES[@]:$1-1}"
	eval "$__gt_text"
}

__gt_run() {
	local line=$__GT_BASE
	trap '__gt_dbg' DEBUG
	while :; do
		__GT_PC=''
		__gt_step "$line"
		[[ -n $__GT_PC ]] || break     # fell off the end: done
		line=${__GT_LBL[$__GT_PC]}     # re-eval from the label
	done
	trap - DEBUG
}

__gt_run "$@"
exit $?
