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
# NB: POSIX shell on purpose - dash cannot parse [[ ]]
if [ -z "${BASH_VERSION:-}" ]; then   # POSIX: dash must parse this
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
__GT_ERREXIT=''
__GT_FELL=''

# pass 0: index the labels by line number, entirely in bash -- this loop is
# the whole "compiler"
mapfile -t __GT_LINES < "$__GT_SRC"
__gt_lbl_re='^[[:space:]]*(label|#[[:space:]]*label|#:)[[:space:]]+'
__gt_lbl_re+='([A-Za-z_][A-Za-z0-9_]*);?[[:space:]]*$'
__gt_hd_re='<<-?[[:space:]]*("|'"'"'|\\)?([A-Za-z_][A-Za-z0-9_]*)'
__gt_hd=''
__gt_hdtab=''
for (( __gt_i = __GT_BASE - 1; __gt_i < ${#__GT_LINES[@]}; __gt_i++ )); do
	__gt_ln=${__GT_LINES[__gt_i]}
	# a `label` line inside a heredoc body is text, not a jump target:
	# indexing it would send the trampoline into the middle of the body
	if [[ -n $__gt_hd ]]; then
		__gt_chk=$__gt_ln
		if [[ -n $__gt_hdtab ]]; then
			while [[ $__gt_chk == $'\t'* ]]; do
				__gt_chk=${__gt_chk#$'\t'}
			done
		fi
		[[ $__gt_chk == "$__gt_hd" ]] && __gt_hd=''
		continue
	fi
	if [[ $__gt_ln != *'(('* && $__gt_ln =~ $__gt_hd_re ]]; then
		__gt_hd=${BASH_REMATCH[2]}
		__gt_hdtab=''
		[[ $__gt_ln == *'<<-'* ]] && __gt_hdtab=1
		continue
	fi
	[[ $__gt_ln =~ $__gt_lbl_re ]] || continue
	__GT_LBL[${BASH_REMATCH[2]}]=$(( __gt_i + 1 ))
done
unset -v __gt_i __gt_lbl_re __gt_hd_re __gt_hd __gt_hdtab __gt_ln __gt_chk

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
		kill -0 "$__GT_SHELL" 2>/dev/null &&
		    kill -s TERM "$__GT_SHELL" 2>/dev/null
		exit 70
	fi
	if [[ -z ${__GT_LBL[$1]+x} ]]; then
		printf 'goto: no such label: %s\n' "$1" >&2
		exit 2
	fi
	# errexit would see the trap's `return 2` as a failing command and
	# kill the shell mid-unwind; remember it and restore after the jump
	__GT_ERREXIT=''
	if [[ $- == *e* ]]; then
		__GT_ERREXIT=1
		set +e
	fi
	__GT_PC=$1
}

# return 2 => bash simulates `return`, one frame per command, until we are
# back in __gt_run (which does the bookkeeping and must not be unwound).
__gt_dbg() {
	[[ -n $__GT_PC && ${FUNCNAME[1]} != __gt_run ]] && return 2
	return 0
}

# tail call: evaluate the program text from line $1 to EOF.  "$@" after
# the line number is the program's own argv, so that $1/$@ inside the
# eval'd text are the script's arguments and not the trampoline's.
__gt_step() {
	local __gt_text=''
	printf -v __gt_text '%s\n' "${__GT_LINES[@]:$1-1}"
	shift
	local __gt_rc=0
	__GT_FELL=''
	[[ -n $__GT_ERREXIT ]] && set -e
	eval "$__gt_text"
	# capture before anything else: this is the program's own status
	__gt_rc=$?
	# only reached when the eval ran to the end - a longjmp unwinds
	# this frame before it, leaving __GT_FELL empty
	__GT_FELL=1
	return $__gt_rc
}

__gt_run() {
	local line=$__GT_BASE rc=0
	trap '__gt_dbg' DEBUG
	while :; do
		__GT_PC=''
		__gt_step "$line" "$@"
		rc=$?                          # before any other command
		set +e                     # keep the trampoline alive
		[[ -n $__GT_PC ]] || break     # fell off the end: done
		# a jump was armed but the text ran to completion anyway:
		# the DEBUG trap that performs the unwind is gone, so the
		# code this jump should have skipped has just run
		if [[ -n $__GT_FELL ]]; then
			printf 'goto: fatal: the DEBUG trap this runtime' >&2
			printf ' needs was replaced or cleared,\n' >&2
			printf '      so `goto %s` could not unwind (the' >&2 \
			    "$__GT_PC"
			printf ' skipped code has run)\n' >&2
			exit 70
		fi
		line=${__GT_LBL[$__GT_PC]}     # re-eval from the label
	done
	trap - DEBUG
	return $rc
}

__gt_run "$@"
exit $?
