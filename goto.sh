#!/usr/bin/env bash
# goto.sh - real forward and backward GOTO for bash 5.x
#
# This is a source-to-source compiler.  It reads a bash program containing
#
#       label NAME          # or:  # label NAME
#       goto NAME           # forward, backward, or computed: goto "$var"
#
# and rewrites it into a single case-dispatch trampoline:
#
#       __GOTO_PC=entry
#       while :; do
#         case $__GOTO_PC in
#           (entry) __GOTO_PC=NAME ; <code> ;;
#           (NAME)  __GOTO_PC=__gt_END ; <code> ;;
#           (__gt_END) break ;;
#         esac
#       done
#
# `goto X` becomes `{ __GOTO_PC=X; continue N; }` where N is the *lexical loop
# nesting depth + 1*, computed at compile time, so a goto works from inside
# arbitrarily nested for/while/until/select/case/if constructs.  Since the pc
# is a string and dispatch is a case, computed gotos (`goto "$dest"`) are free.
#
# The front end is bash itself: the program text is parsed by `eval`ing it as
# a function body and then read back with `declare -f`, which pretty-prints
# the shell's *parse tree* in canonical form (one command per line, canonical
# quoting, 4-space indent per nesting level, aliases already expanded).  That
# turns "write a bash parser" into "scan a canonical token stream".
#
# Usage
#   1.  source goto.sh          # at the top of your script; compiles and runs
#                               # the remainder of the calling file, then exits
#   2.  goto.sh prog.sh [args]  # run prog.sh as a goto program
#   3.  goto.sh -E prog.sh      # dump the compiled trampoline, don't run it
#   4.  eval "$(goto_compile <<'EOF' ... EOF)"     # heredoc form, no tmp file
#
# Environment
#   GOTO_EMIT=1     print the compiled program to stderr before running it
#   GOTO_STRICT=0   disable the runtime "goto crossed a subshell" guard
#
# Limitations (all diagnosed at compile time or trapped at run time):
#   * labels must sit at the top level of the program (as in C, where goto
#     is function-local)
#   * a goto may not cross a subshell or pipeline boundary (trapped at
#     run time)
#   * bare `break`/`continue` outside your own loops is rejected: it would
#     hijack the trampoline
#
# Style note: the compiler's per-line helpers (__gt_err, __gt_classify,
# __gt_chk_stray, __gt_rw_ret, __gt_rw_goto) deliberately read and write
# their caller's variables through bash's dynamic scoping; they are private
# extensions of __gt_compile_body, split out to keep each function small.

# shellcheck disable=SC2016,SC1003
# (SC2016: single-quoted strings with $ are emitted-code literals that must
#  not expand here; SC1003: '\' is a deliberate one-character backslash.)

# the runtimes lean on bash 5 behavior (negative array subscripts, mapfile,
# BASHPID, extdebug details); fail loudly instead of confusingly on old bash
if (( BASH_VERSINFO[0] < 5 )); then
	printf 'goto.sh: bash >= 5 required (this is bash %s)\n' \
	    "$BASH_VERSION" >&2
	# sourced from an interactive shell: return; anywhere else the
	# program cannot run, so exit
	if [[ ${BASH_SOURCE[0]} != "$0" ]] &&
	    (( ${#BASH_SOURCE[@]} == 1 )); then
		return 2
	fi
	exit 2
fi

__GT_VERSION='1.0.0'

# ---------------------------------------------------------------------------
# runtime words (also make an *uncompiled* run of the program parse cleanly)
# ---------------------------------------------------------------------------
label() { :; }

goto() {
	printf 'goto: %s: program was not compiled by goto.sh\n' "${1-}" >&2
	return 127
}

gosub() { goto "${1-}"; }

ret() { goto '<ret>'; }

# pop the gosub stack into the pc
__gt_ret() {
	if (( ${#__GOTO_STACK[@]} == 0 )); then
		printf 'goto: ret with empty gosub stack\n' >&2
		exit 2
	fi
	__GOTO_PC=${__GOTO_STACK[-1]}
	unset '__GOTO_STACK[-1]'
}

# runtime guard: a compiled goto executed in a subshell or pipeline
__gt_fault() {
	printf 'goto: fatal: `goto %s` executed in a subshell' "$1" >&2
	printf ' or pipeline (pid %s != %s)\n' "$BASHPID" "$__GOTO_SHELL" >&2
	kill -s TERM "$__GOTO_SHELL" 2>/dev/null
	exit 70
}

__gt_die() {
	printf 'goto.sh: %s\n' "$*" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# pass 0 - source acquisition + comment-label sugar
#          `# label foo` / `#: foo` become the real command `label foo`
# ---------------------------------------------------------------------------
__gt_pass0() {
	local src_re='^[[:space:]]*(source|\.)[[:space:]].*goto(_trap)?\.sh'
	local lbl1_re lbl2_re
	lbl1_re='^[[:space:]]*#[[:space:]]*label[[:space:]]+'
	lbl1_re+='([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$'
	lbl2_re='^[[:space:]]*#:[[:space:]]*'
	lbl2_re+='([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$'
	local line out='' first=1
	while IFS= read -r line || [[ -n $line ]]; do
		if (( first )); then
			first=0
			if [[ $line == '#!'* ]]; then
				out+=$'\n'
				continue
			fi
		fi
		# a 'source .../goto.sh' line inside the program itself is
		# the preamble, not part of the program: drop it so that -E
		# output is runnable as-is
		if [[ $line =~ $src_re ]]; then
			out+=$'\n'
			continue
		fi
		if [[ $line =~ $lbl1_re || $line =~ $lbl2_re ]]; then
			out+="label ${BASH_REMATCH[1]}"$'\n'
		else
			out+="$line"$'\n'
		fi
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# pass 1 - parse with bash, read the parse tree back with declare -f
# ---------------------------------------------------------------------------
__gt_pass1() {
	local src=$1 body err line
	shopt -s expand_aliases           # give the program cpp-style macros
	local def="__gt_program() {
$src
}"
	# dry-run the parse in a subshell to capture any syntax error, then
	# define the function for real in this shell (a function definition
	# has no side effects, so parsing twice is safe)
	if ! err=$(eval "$def" 2>&1); then
		printf 'goto.sh: syntax error in program:\n' >&2
		while IFS= read -r line; do
			printf '  %s\n' "$line"
		done <<<"$err" >&2
		return 2
	fi
	eval "$def"
	body=$(declare -f __gt_program)
	unset -f __gt_program
	body=${body#*$'\n'}               # drop "__gt_program () "
	body=${body#*$'\n'}               # drop "{ "
	body=${body%$'\n'\}}              # drop trailing "\n}"
	printf '%s\n' "$body"
}

# ---------------------------------------------------------------------------
# pass 2 - mask quoted text and heredoc bodies, preserving offsets and
#          newlines so that pass 3 can scan for keywords without tripping
#          over `echo "done"` or a heredoc containing the word `label`
# ---------------------------------------------------------------------------
__gt_mask() {
	local s=$1
	local n=${#s} i=0 c out='' q='' hd='' hdtab='' chk ln='' j d
	local -a pend=()
	while (( i < n )); do
		c=${s:i:1}
		# inside a heredoc body: everything is masked; a line equal
		# to the delimiter (minus leading tabs for <<-) ends the body
		if [[ -n $hd ]]; then
			if [[ $c == $'\n' ]]; then
				chk=$ln
				if [[ -n $hdtab ]]; then
					while [[ $chk == $'\t'* ]]; do
						chk=${chk#$'\t'}
					done
				fi
				[[ $chk == "$hd" ]] && hd=
				out+=$'\n'
				ln=
			else
				out+=X
				ln+=$c
			fi
			(( i++ ))
			continue
		fi
		# inside a single-quoted string
		if [[ $q == "'" ]]; then
			if [[ $c == "'" ]]; then
				q=
				out+="'"
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'  # keep mask/source lines aligned
			else
				out+=X
			fi
			(( i++ ))
			continue
		fi
		# inside a double-quoted string
		if [[ $q == '"' ]]; then
			if [[ $c == '\' ]]; then
				if [[ ${s:i+1:1} == $'\n' ]]; then
					out+=X$'\n'
				else
					out+=XX
				fi
				(( i += 2 ))
			elif [[ $c == '"' ]]; then
				q=
				out+='"'
				(( i++ ))
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'
				(( i++ ))
			else
				out+=X
				(( i++ ))
			fi
			continue
		fi
		# bare code
		case $c in
		"'"|'"')
			q=$c
			out+=$c
			;;
		'\')
			out+='\'
			if [[ ${s:i+1:1} == $'\n' ]]; then
				out+=$'\n'
			else
				out+=X
			fi
			(( i++ ))
			;;
		'<')
			if [[ ${s:i+1:1} == '<' ]]; then
				if [[ ${s:i+2:1} == '<' ]]; then
					out+='<<<'  # herestring, no heredoc
					(( i += 3 ))
					continue
				fi
				j=$(( i + 2 ))
				d=
				hdtab=
				if [[ ${s:j:1} == '-' ]]; then
					hdtab=1
					(( j++ ))
				fi
				while [[ ${s:j:1} == ' ' ]]; do
					(( j++ ))
				done
				while (( j < n )) &&
				    [[ ${s:j:1} != [$' \t\n;&|<>'] ]]; do
					case ${s:j:1} in
					"'"|'"'|'\') ;;  # quote removal
					*) d+=${s:j:1} ;;
					esac
					(( j++ ))
				done
				pend+=("$d")
				out+='<<'
				(( i += 2 ))
				continue
			fi
			out+=$c
			;;
		$'\n')
			out+=$'\n'
			if (( ${#pend[@]} )); then
				hd=${pend[0]}
				pend=("${pend[@]:1}")
				ln=
			fi
			;;
		*)
			out+=$c
			;;
		esac
		(( i++ ))
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# tokenizer over a masked line: emits "OFFSET LENGTH CMDPOS TEXT" per token.
# CMDPOS=1 means the token is in command position, i.e. it is the first word
# of a command, which is the only place bash treats `do`/`done`/`label` as
# words that matter to us.
# ---------------------------------------------------------------------------
__gt_tokens() {
	local l=$1
	local n=${#l} i=0 c tok start cmd=1
	while (( i < n )); do
		c=${l:i:1}
		case $c in
		' '|$'\t')
			(( i++ ))
			continue
			;;
		';'|'&'|'|')
			start=$i
			tok=$c
			(( i++ ))
			[[ ${l:i:1} == "$c" ]] && { tok+=$c; (( i++ )); }
			printf '%s %s %s %s\n' "$start" "${#tok}" 0 "$tok"
			cmd=1
			continue
			;;
		'('|')'|'{'|'}')
			printf '%s %s %s %s\n' "$i" 1 0 "$c"
			(( i++ ))
			cmd=1
			continue
			;;
		*)
			start=$i
			tok=
			while (( i < n )); do
				c=${l:i:1}
				[[ $c == [' '$'\t'';&|()'] ]] && break
				tok+=$c
				(( i++ ))
			done
			printf '%s %s %s %s\n' "$start" "${#tok}" "$cmd" "$tok"
			case $tok in
			'!'|time|then|else|elif|do|in) cmd=1 ;;
			*) cmd=0 ;;
			esac
			;;
		esac
	done
}

# ---------------------------------------------------------------------------
# pass 3 + 4 - scan the canonical body, validate, and emit the trampoline.
# The helpers below run with __gt_compile_body's locals in dynamic scope.
# ---------------------------------------------------------------------------

# report a compile error and count it in the caller's `errs`
__gt_err() {
	printf 'goto.sh: error: %s\n' "$*" >&2
	(( ++errs ))
}

# classify a `label NAME` / `gosub NAME` line; sets kind[i] and returns 0,
# or returns 1 to let the line fall through to the ordinary code scan
__gt_classify() {
	local name
	if [[ $trimmed =~ $gosub_re ]]; then
		name=${BASH_REMATCH[1]}
		if (( indent != 4 || loops != 0 )); then
			__gt_err "gosub $name must be at the top level" \
			    '(it needs a return label)'
			return 1
		fi
		(( ++gsn ))
		kind[i]="GOSUB $name __gt_ret$gsn"
		gsub_targets+=("$name")
		return 0
	fi
	[[ $trimmed =~ $label_re ]] || return 1
	name=${BASH_REMATCH[1]}
	if (( indent != 4 || loops != 0 )); then
		__gt_err "label $name is not at the top level" \
		    'of the program'
		printf '%16s%s\n' '' \
		    '(bash cannot jump into a loop, function or block)' >&2
		return 1
	fi
	if [[ -n ${seen[$name]-} ]]; then
		__gt_err "duplicate label $name"
		return 1
	fi
	seen[$name]=1
	labels+=("$name")
	kind[i]="LABEL $name"
	return 0
}

# a bare `break`/`continue` at loop depth 0 would hijack the trampoline
__gt_chk_stray() {
	(( loops == 0 )) || return 0
	local shown=${sl#"${sl%%[![:space:]]*}"}
	__gt_err "\`$tok\` outside any loop would hijack" \
	    "the trampoline (line: $shown)"
}

# rewrite the `ret` token at $off on the current line
__gt_rw_ret() {
	local repl="{ __gt_ret; continue $(( loops + 1 )); }"
	local head=${rewritten:0:off+delta}
	local tail=${rewritten:off+delta+3}
	rewritten=$head$repl$tail
	(( delta += ${#repl} - 3 ))
}

# rewrite the `goto TARGET` starting at $off on the current line
__gt_rw_goto() {
	local toff=$(( off + len )) tlen=0
	while [[ ${ml:toff:1} == [' '$'\t'] ]]; do
		(( toff++ ))
	done
	while (( toff + tlen < ${#ml} )) &&
	    [[ ${ml:toff+tlen:1} != [' '$'\t'';&|'] ]]; do
		(( tlen++ ))
	done
	if (( tlen == 0 )); then
		__gt_err '`goto` without a target'
		return 0
	fi
	local target=${sl:toff:tlen} guard=''
	# a bare target must be a label name; anything else means the goto
	# sits inside $( )/( ) or the target is an unquoted expansion
	if [[ $target != [\$\"\'\`]* && ! $target =~ $tgt_re ]]; then
		__gt_err "goto target $target is not a valid label name"
		printf '%16s%s\n' '' \
		    '(quote computed targets: goto "$var"; a goto' >&2
		printf '%16s%s\n' '' \
		    'cannot cross $( ), ( ) or a pipeline)' >&2
		return 0
	fi
	if [[ ${GOTO_STRICT-1} != 0 ]]; then
		guard='[[ $BASHPID == "$__GOTO_SHELL" ]]'
		guard+=" || __gt_fault $target; "
	fi
	local repl="{ __GOTO_PC=$target; ${guard}continue $(( loops + 1 )); }"
	local head=${rewritten:0:off+delta}
	local tail=${rewritten:off+delta+toff+tlen-off}
	rewritten=$head$repl$tail
	(( delta += ${#repl} - (toff + tlen - off) ))
	# static targets are validated after the scan; computed targets
	# (quoted or $-expanded) are checked by the trampoline at run time
	[[ $target == [\$\"\'\`]* ]] || gtargets+=("$target")
}

__gt_compile_body() {
	local gosub_re='^gosub[[:space:]]+([A-Za-z_][A-Za-z0-9_]*);?$'
	local label_re='^label[[:space:]]+([A-Za-z_][A-Za-z0-9_]*);?$'
	local tgt_re='^[A-Za-z_][A-Za-z0-9_]*$'
	local body=$1 masked
	masked=$(__gt_mask "$body")

	local -a src mask
	mapfile -t src <<<"$body"
	mapfile -t mask <<<"$masked"

	local -a labels=() kind=() gtargets=() gsub_targets=()
	local -A seen=()
	local i loops=0 off len cmd tok errs=0 gsn=0

	# ---- scan -------------------------------------------------------
	for (( i = 0; i < ${#src[@]}; i++ )); do
		local ml=${mask[i]} sl=${src[i]} trimmed indent
		trimmed=${ml#"${ml%%[![:space:]]*}"}
		indent=$(( ${#ml} - ${#trimmed} ))

		__gt_classify && continue
		kind[i]=CODE

		# walk the tokens for loop depth, goto/ret rewriting, and
		# stray break/continue detection
		local rewritten=$sl delta=0
		while read -r off len cmd tok; do
			(( cmd == 1 )) || continue
			case $tok in
			do) (( loops++ )) ;;
			done) (( loops > 0 )) && (( loops-- )) ;;
			break|continue) __gt_chk_stray ;;
			ret) __gt_rw_ret ;;
			goto) __gt_rw_goto ;;
			esac
		done < <(__gt_tokens "$ml")
		src[i]=$rewritten
	done

	if (( loops != 0 )); then
		printf 'goto.sh: internal: unbalanced do/done (%d)\n' \
		    "$loops" >&2
		(( ++errs ))
	fi
	(( errs == 0 )) || return 2

	# every static goto and gosub target must exist
	local g
	local -A flagged=()
	for g in "${gtargets[@]}"; do
		[[ -n ${seen[$g]-} || -n ${flagged[$g]-} ]] && continue
		flagged[$g]=1
		__gt_err "goto to undefined label: $g"
	done
	for g in "${gsub_targets[@]}"; do
		[[ -n ${seen[$g]-} || -n ${flagged[$g]-} ]] && continue
		flagged[$g]=1
		__gt_err "gosub to undefined label: $g"
	done
	(( errs == 0 )) || return 2

	# ---- emit -------------------------------------------------------
	# ends[] tracks what a segment body ends with: user code needs a
	# status capture so falling off the end propagates $?, while a
	# generated gosub jump makes anything after it unreachable
	local -a names=('__gt_entry') bodies=('') ends=('')
	local n=0 next gs tgt rl
	for (( i = 0; i < ${#src[@]}; i++ )); do
		if [[ ${kind[i]} == LABEL\ * ]]; then
			names+=("${kind[i]#LABEL }")
			bodies+=('')
			ends+=('')
			(( ++n ))
		elif [[ ${kind[i]} == GOSUB\ * ]]; then
			gs=${kind[i]#GOSUB }
			tgt=${gs%% *}
			rl=${gs##* }
			bodies[n]+="      { __GOTO_STACK+=($rl);"
			bodies[n]+=" __GOTO_PC=$tgt; continue 1; }"$'\n'
			ends[n]=gosub
			names+=("$rl")
			bodies+=('')
			ends+=('')
			(( ++n ))
		else
			bodies[n]+="${src[i]}"$'\n'
			ends[n]=code
		fi
	done

	printf '# ---- compiled by goto.sh: %d label(s), %d segment(s)' \
	    "${#labels[@]}" "${#names[@]}"
	printf ' ----\n'
	printf 'declare -g __GOTO_SHELL=$BASHPID __GOTO_PC=__gt_entry\n'
	printf 'declare -ga __GOTO_STACK=()\n'
	printf 'declare -g __GOTO_RC=0\n'
	printf 'while :; do\n  case $__GOTO_PC in\n'
	for (( i = 0; i < ${#names[@]}; i++ )); do
		next=__gt_END
		(( i + 1 < ${#names[@]} )) && next=${names[i+1]}
		printf '    (%s)\n      __GOTO_PC=%s\n' "${names[i]}" "$next"
		if [[ -n ${bodies[i]//[[:space:]]/} ]]; then
			printf '%s' "${bodies[i]}"
			if [[ ${ends[i]} == code ]]; then
				printf '      __GOTO_RC=$?\n'
			fi
		else
			printf '      :\n'
		fi
		printf '      ;;\n'
	done
	printf '    (__gt_END) break ;;\n'
	printf '    (*) printf "goto: no such label: %%s\\n"'
	printf ' "$__GOTO_PC" >&2; exit 2 ;;\n'
	printf '  esac\ndone\n'
	printf '(exit "$__GOTO_RC")\n'
}

# ---------------------------------------------------------------------------
# public entry points
# ---------------------------------------------------------------------------

# usage: goto_compile [file]    (default stdin) -> compiled bash on stdout
goto_compile() {
	local src parsed
	if (( $# )); then
		src=$(__gt_pass0 < "$1")
	else
		src=$(__gt_pass0)
	fi
	parsed=$(__gt_pass1 "$src") || return $?
	__gt_compile_body "$parsed"
}

# program text on stdin -> compile and run in the current shell.
# NB: stdin is consumed by the compile, so the program inherits it at EOF.
goto_run() {
	local prog
	prog=$(goto_compile) || return $?
	[[ ${GOTO_EMIT-0} == 1 ]] && printf '%s\n' "$prog" >&2
	eval "$prog"
}

# ---------------------------------------------------------------------------
# dispatch: sourced from a program, or invoked as a command
# ---------------------------------------------------------------------------
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
	# `source goto.sh --lib` -- just define goto_compile/goto_run
	# `source goto.sh`       -- take over the rest of the calling file
	if [[ ${1-} != --lib ]] && (( ${#BASH_SOURCE[@]} > 1 )) &&
	    [[ -r ${BASH_SOURCE[1]} ]]; then
		mapfile -t __gt_lines < "${BASH_SOURCE[1]}"
		__gt_prog=$(goto_compile < <(
			printf '%s\n' "${__gt_lines[@]:BASH_LINENO[0]}"
		)) || exit $?
		[[ ${GOTO_EMIT-0} == 1 ]] && printf '%s\n' "$__gt_prog" >&2
		unset -v __gt_lines
		eval "$__gt_prog"
		exit $?
	fi
	# sourced interactively / from a library: just provide the functions
else
	case ${1-} in
	-E|--emit)
		shift
		[[ ${1-} ]] || __gt_die 'usage: goto.sh -E prog.sh'
		goto_compile "$1"
		;;
	-V|--version)
		printf 'goto.sh %s\n' "$__GT_VERSION"
		;;
	-h|--help)
		while IFS= read -r __gt_line; do
			[[ $__gt_line == '#!'* ]] && continue
			[[ $__gt_line == '#'* ]] || break
			printf '%s\n' "$__gt_line"
		done < "${BASH_SOURCE[0]}"
		;;
	'')
		goto_run                     # program on stdin
		;;
	*)
		[[ -r $1 ]] || __gt_die "cannot read $1"
		__gt_file=$1
		shift                        # rest of "$@" is the argv
		__gt_prog=$(goto_compile "$__gt_file") || exit $?
		[[ ${GOTO_EMIT-0} == 1 ]] && printf '%s\n' "$__gt_prog" >&2
		unset -v __gt_file
		eval "$__gt_prog"            # top level: real $@, stdin
		exit $?
		;;
	esac
fi
