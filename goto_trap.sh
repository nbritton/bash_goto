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
# shellcheck disable=SC2317,SC2016,SC1003,SC2329
# (SC2016: the fatal-goto message quotes a literal `goto %s` on purpose.)
# (SC1003: '\' is a deliberate one-character backslash.)
# (label/goto/__gt_dbg look unreachable to static analysis under both its
#  legacy and current checks: the sourcing program and DEBUG trap call them.)
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

# Append the live heredoc delimiters on one source line to __gt_hdp.
# Lexical quote/arithmetic state carries across lines so text such as
# `echo "<<NOT_A_HEREDOC"` cannot hide the real labels below it.
__gt_hd_scan() {
	local l=$1 n=${#1} i=0 c prev next j d dq tab x old
	while (( i < n )); do
		c=${l:i:1}
		if [[ $__gt_hdq == "'" ]]; then
			[[ $c == "'" ]] && __gt_hdq=
			(( i++ ))
			continue
		elif [[ $__gt_hdq == A ]]; then
			if [[ $c == '\' ]]; then
				(( i += 2 ))
				continue
			fi
			[[ $c == "'" ]] && __gt_hdq=
			(( i++ ))
			continue
		elif [[ $__gt_hdq == '"' ]]; then
			if [[ $c == '\' ]]; then
				(( i += 2 ))
				continue
			elif [[ $c == '$' && ${l:i+1:1} == '(' &&
			    ${l:i+2:1} != '(' ]]; then
				(( ++__gt_hds ))
				__gt_hdr[__gt_hds]='"'
				__gt_hdq=
				(( i += 2 ))
				continue
			fi
			[[ $c == '"' ]] && __gt_hdq=
			(( i++ ))
			continue
		fi
		prev=
		(( i > 0 )) && prev=${l:i-1:1}
		case $c in
		'$')
			if [[ ${l:i+1:1} == '(' &&
			    ${l:i+2:1} != '(' ]]; then
				(( ++__gt_hds ))
				unset '__gt_hdr[__gt_hds]'
				(( i++ ))
			fi
			;;
		"'")
			if [[ $prev == '$' ]]; then
				__gt_hdq=A
			else
				__gt_hdq="'"
			fi
			;;
		'"') __gt_hdq='"' ;;
		'\') (( i++ )) ;;
		'#')
			if (( i == 0 )) ||
			    [[ $prev == [$' \t;&|()'] ]]; then
				break
			fi
			;;
		'(')
			if [[ ${l:i+1:1} == '(' ]]; then
				(( ++__gt_hda ))
				(( i++ ))
			elif (( __gt_hds > 0 )); then
				(( ++__gt_hds ))
				unset '__gt_hdr[__gt_hds]'
			fi
			;;
		')')
			if (( __gt_hda > 0 )) &&
			    [[ ${l:i+1:1} == ')' ]]; then
				(( --__gt_hda ))
				(( i++ ))
			elif (( __gt_hds > 0 )); then
				old=$__gt_hds
				(( --__gt_hds ))
				if [[ -n ${__gt_hdr[old]+x} ]]; then
					__gt_hdq=${__gt_hdr[old]}
					unset '__gt_hdr[old]'
				fi
			fi
			;;
		'<')
			if [[ ${l:i+1:1} != '<' ]] ||
			    [[ ${l:i+2:1} == '<' ]] ||
			    (( __gt_hda > 0 )); then
				(( i++ ))
				continue
			fi
			j=$(( i + 2 ))
			d=
			dq=
			tab=
			if [[ ${l:j:1} == '-' ]]; then
				tab=1
				(( j++ ))
			fi
			while [[ ${l:j:1} == [' '$'\t'] ]]; do
				(( j++ ))
			done
			while (( j < n )); do
				x=${l:j:1}
				if [[ $dq == "'" ]]; then
					if [[ $x == "'" ]]; then
						dq=
					else
						d+=$x
					fi
				elif [[ $dq == A ]]; then
					if [[ $x == "'" ]]; then
						dq=
					elif [[ $x == '\' ]]; then
						(( j++ ))
						d+=${l:j:1}
					else
						d+=$x
					fi
				elif [[ $dq == '"' ]]; then
					if [[ $x == '"' ]]; then
						dq=
					elif [[ $x == '\' ]]; then
						(( j++ ))
						d+=${l:j:1}
					else
						d+=$x
					fi
				else
					case $x in
					"'"|'"') dq=$x ;;
					'$')
						next=${l:j+1:1}
						if [[ $next == "'" ]]; then
							dq=A
							(( j++ ))
						elif [[ $next == '"' ]]; then
							dq='"'
							(( j++ ))
						else
							d+=$x
						fi
						;;
					'\')
						(( j++ ))
						d+=${l:j:1}
						;;
					[$' \t;&|<>']) break ;;
					*) d+=$x ;;
					esac
				fi
				(( j++ ))
			done
			__gt_hdp+=("$d")
			__gt_hdpt+=("$tab")
			i=$(( j - 1 ))
			;;
		esac
		(( i++ ))
	done
}

# pass 0: index the labels by line number, entirely in bash -- this loop is
# the whole "compiler"
mapfile -t __GT_LINES < "$__GT_SRC"
__gt_lbl_re='^[[:space:]]*(label|#[[:space:]]*label|#:)[[:space:]]+'
__gt_lbl_re+='([A-Za-z_][A-Za-z0-9_]*);?[[:space:]]*$'
__gt_hd=''
__gt_hdtab=''
__gt_hdactive=''
__gt_hdq=''
__gt_hda=0
__gt_hds=0
declare -a __gt_hdp=() __gt_hdpt=() __gt_hdr=()
for (( __gt_i = __GT_BASE - 1; __gt_i < ${#__GT_LINES[@]}; __gt_i++ )); do
	__gt_ln=${__GT_LINES[__gt_i]}
	# a `label` line inside a heredoc body is text, not a jump target:
	# indexing it would send the trampoline into the middle of the body
	if [[ -n $__gt_hdactive ]]; then
		__gt_chk=$__gt_ln
		if [[ -n $__gt_hdtab ]]; then
			while [[ $__gt_chk == $'\t'* ]]; do
				__gt_chk=${__gt_chk#$'\t'}
			done
		fi
		if [[ $__gt_chk == "$__gt_hd" ]]; then
			if (( ${#__gt_hdp[@]} )); then
				__gt_hd=${__gt_hdp[0]}
				__gt_hdtab=${__gt_hdpt[0]}
				__gt_hdp=("${__gt_hdp[@]:1}")
				__gt_hdpt=("${__gt_hdpt[@]:1}")
			else
				__gt_hdactive=
			fi
		fi
		continue
	fi
	__gt_lineq=$__gt_hdq
	if [[ -n $__gt_hdq ]] ||
	    (( __gt_hda > 0 || __gt_hds > 0 )) ||
	    [[ $__gt_ln == *'<'* || $__gt_ln == *"'"* ||
	    $__gt_ln == *'"'* || $__gt_ln == *'(('* ]]; then
		__gt_hd_scan "$__gt_ln"
	fi
	if (( ${#__gt_hdp[@]} )); then
		__gt_hd=${__gt_hdp[0]}
		__gt_hdtab=${__gt_hdpt[0]}
		__gt_hdactive=1
		__gt_hdp=("${__gt_hdp[@]:1}")
		__gt_hdpt=("${__gt_hdpt[@]:1}")
	fi
	[[ -z $__gt_lineq && $__gt_ln =~ $__gt_lbl_re ]] || continue
	__gt_name=${BASH_REMATCH[2]}
	if [[ -n ${__GT_LBL[$__gt_name]+x} ]]; then
		printf 'goto_trap.sh: duplicate label: %s\n' \
		    "$__gt_name" >&2
		exit 2
	fi
	__GT_LBL[$__gt_name]=$(( __gt_i + 1 ))
done
unset -f __gt_hd_scan
unset -v __gt_i __gt_lbl_re __gt_hd __gt_hdtab __gt_hdactive
unset -v __gt_hdq __gt_hda __gt_hds __gt_hdr __gt_hdp __gt_hdpt
unset -v __gt_ln __gt_chk
unset -v __gt_name __gt_lineq

label() { :; }

# arm the longjmp
goto() {
	local target=${1-}
	if [[ -z $target ]]; then
		printf 'goto: missing label\n' >&2
		exit 2
	fi
	if (( $# != 1 )); then
		printf 'goto: expected exactly one label\n' >&2
		exit 2
	fi
	# a goto in a subshell or pipeline can never reach the trampoline;
	# without this guard the jump would just be silently lost
	if [[ ${GOTO_STRICT-1} != 0 && $BASHPID != "$__GT_SHELL" ]]; then
		printf 'goto: fatal: `goto %s` executed in a subshell' \
		    "$target" >&2
		printf ' or pipeline (pid %s != %s)\n' \
		    "$BASHPID" "$__GT_SHELL" >&2
		kill -0 "$__GT_SHELL" 2>/dev/null &&
		    kill -s TERM "$__GT_SHELL" 2>/dev/null
		exit 70
	fi
	if [[ -z ${__GT_LBL[$target]+x} ]]; then
		printf 'goto: no such label: %s\n' "$target" >&2
		exit 2
	fi
	# errexit would see the trap's `return 2` as a failing command and
	# kill the shell mid-unwind; remember it and restore after the jump
	__GT_ERREXIT=''
	if [[ $- == *e* ]]; then
		__GT_ERREXIT=1
		set +e
	fi
	__GT_PC=$target
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
