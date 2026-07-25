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

# sourced by zsh or another non-bash shell?  refuse politely: an `exit`
# here would close the user's interactive shell (macOS defaults to zsh)
# NB: written in POSIX shell on purpose - dash cannot parse [[ ]] and
# would die here rather than print this message
if [ -z "${BASH_VERSION:-}" ]; then   # POSIX: dash must parse this
	printf 'goto.sh: this is a bash tool and cannot run under this\n' >&2
	printf 'shell; put `source goto.sh` in a bash script, or try:\n' >&2
	printf '  bash examples/01_forward_and_backward.sh\n' >&2
	return 2 2>/dev/null
	# shellcheck disable=SC2317
	# (reached when goto.sh is *executed* by a non-bash shell)
	exit 2
fi

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

__GT_VERSION='1.0.1'

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
	# only signal a shell that is still alive: after PID reuse the
	# recorded pid could belong to something else entirely
	kill -0 "$__GOTO_SHELL" 2>/dev/null &&
	    kill -s TERM "$__GOTO_SHELL" 2>/dev/null
	exit 70
}

# refuse to continue: exit a script, but merely return in an interactive
# shell, where exiting would close the user's session
__gt_refuse() {
	if [[ $- == *i* ]]; then
		return 2
	fi
	exit 2
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
	# only a *whole* `source .../goto.sh` line is the preamble: an
	# unanchored match would also delete `source ./lib_nogoto.sh`
	local src_re='^[[:space:]]*(source|\.)[[:space:]]+("|'"'"')?'
	src_re+='([^"'"'"']*/)?goto(_trap)?\.sh("|'"'"')?[[:space:]]*$'
	# a heredoc opener, but not the `<<` of an arithmetic left shift
	local hd_re='<<-?[[:space:]]*("|'"'"'|\\)?([A-Za-z_][A-Za-z0-9_]*)'
	local hd='' hdtab=''
	local lbl1_re lbl2_re
	lbl1_re='^[[:space:]]*#[[:space:]]*label[[:space:]]+'
	lbl1_re+='([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$'
	lbl2_re='^[[:space:]]*#:[[:space:]]*'
	lbl2_re+='([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$'
	local line out='' first=1 chk
	while IFS= read -r line || [[ -n $line ]]; do
		if (( first )); then
			first=0
			if [[ $line == '#!'* ]]; then
				out+=$'\n'
				continue
			fi
		fi
		# inside a heredoc body nothing is a command or a comment,
		# so pass the text through untouched until the delimiter
		if [[ -n $hd ]]; then
			chk=$line
			if [[ -n $hdtab ]]; then
				while [[ $chk == $'\t'* ]]; do
					chk=${chk#$'\t'}
				done
			fi
			[[ $chk == "$hd" ]] && hd=''
			out+="$line"$'\n'
			continue
		fi
		if [[ $line != *'(('* && $line =~ $hd_re ]]; then
			hd=${BASH_REMATCH[2]}
			hdtab=''
			[[ $line == *'<<-'* ]] && hdtab=1
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
	local src=$1 body err line trimmed
	shopt -s expand_aliases           # give the program cpp-style macros
	# bash cannot parse a function body that is empty or all comments,
	# so give an empty program an explicit no-op
	body=''
	while IFS= read -r line; do
		trimmed=${line#"${line%%[![:space:]]*}"}
		[[ -z $trimmed || $trimmed == '#'* ]] && continue
		body=1
		break
	done <<<"$src"
	[[ -n $body ]] || src=':'
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
	local arith=0
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
		# inside a `...` command substitution: mask it like a quoted
		# region so its words never reach the scanner (a goto in there
		# cannot work anyway - it would run in a subshell - and is
		# rejected separately by __gt_chk_subst)
		if [[ $q == '`' ]]; then
			if [[ $c == '`' ]]; then
				q=
				out+='`'
			elif [[ $c == $'\n' ]]; then
				out+=$'\n'
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
		"'"|'"'|'`')
			q=$c
			out+=$c
			;;
		'(')
			# `((` opens an arithmetic context.  Canonical bash
			# output writes nested subshells as `( (` with a
			# space, so an unspaced `((` here is always
			# arithmetic - and inside it, `<<` is a left shift,
			# not a heredoc.
			if [[ ${s:i+1:1} == '(' ]]; then
				(( ++arith ))
				out+='(('
				(( i += 2 ))
				continue
			fi
			out+=$c
			;;
		')')
			if (( arith > 0 )) && [[ ${s:i+1:1} == ')' ]]; then
				(( --arith ))
				out+='))'
				(( i += 2 ))
				continue
			fi
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
			# inside (( )) a `<<` is a left shift, not a heredoc
			if [[ ${s:i+1:1} == '<' ]] && (( arith == 0 )); then
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
			# NB: `in` is deliberately absent - the word after
			# `in` starts a for/select *word list*, which is
			# data, not a command (`for x in done; ...`)
			case $tok in
			'!'|time|then|else|elif|do) cmd=1 ;;
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

# is the current line a `case` pattern rather than a command?  In canonical
# bash output a pattern occupies its own line and closes a paren it never
# opened, which no ordinary command line does.
__gt_is_pattern() {
	local rest=${trimmed%)*} opens=0 closes=0 t
	[[ $trimmed == *')' ]] || return 1
	t=${trimmed//[!(]/}
	opens=${#t}
	t=${trimmed//[!)]/}
	closes=${#t}
	(( closes > opens ))
}

# `goto`/`ret`/`gosub` inside a `...` command substitution: the masker has
# blanked it, so it would silently never be compiled
__gt_chk_backtick() {
	local rest=$sl before after seg
	[[ $ml == *'`'*'`'* ]] || return 0
	# walk the masked line for backtick pairs and test the same span
	# of the real source line
	local p=0 a b
	while :; do
		a=${ml:p}
		[[ $a == *'`'* ]] || break
		before=${a%%'`'*}
		(( a = p + ${#before} + 1 ))
		rest=${ml:a}
		[[ $rest == *'`'* ]] || break
		after=${rest%%'`'*}
		(( b = a + ${#after} ))
		seg=${sl:a:b-a}
		if [[ $seg =~ $kw_re ]]; then
			__gt_err "\`${BASH_REMATCH[2]}\` inside a \`...\`" \
			    'command substitution can never jump'
			printf '%16s%s\n' '' \
			    '(it runs in a subshell; move it outside)' >&2
			return 0
		fi
		p=$(( b + 1 ))
	done
}

# `gosub` that survived __gt_classify is not a plain top-level `gosub NAME`,
# so it would fall through to the uncompiled runtime stub
__gt_chk_gosub() {
	__gt_err 'gosub must be a plain `gosub NAME` at the top level'
	printf '%16s%s\n' '' \
	    '(it needs a return label, so it cannot be conditional)' >&2
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
		(( ++toff ))
	done
	# `)` and `(` terminate the target too, so that a goto inside a
	# command substitution yields a clean diagnostic instead of a
	# target with a stray paren glued to it
	while (( toff + tlen < ${#ml} )) &&
	    [[ ${ml:toff+tlen:1} != [' '$'\t'';&|()'] ]]; do
		(( ++tlen ))
	done
	if (( tlen == 0 )); then
		__gt_err '`goto` without a target'
		return 0
	fi
	local target=${sl:toff:tlen} guard=''
	# a goto inside a function is function-local, as in C: bash would
	# reject the emitted `continue` at run time, so reject it here
	if (( ${#fns[@]} )); then
		__gt_err 'goto inside a function body cannot leave it' \
		    '(goto is function-local, as in C)'
		printf '%16s%s\n' '' \
		    '(use goto_trap.sh if you need to jump out of a call)' >&2
		return 0
	fi
	# an unclosed `(` before the goto means it sits inside $( ) or ( ),
	# where a jump could never reach the trampoline
	local pre=${ml:0:off} po pc
	po=${pre//[!(]/}
	pc=${pre//[!)]/}
	if (( ${#po} > ${#pc} )); then
		__gt_err 'goto cannot cross a subshell or command' \
		    'substitution'
		printf '%16s%s\n' '' \
		    '(the jump would run in a child process)' >&2
		return 0
	fi
	# a bare target must be a label name; anything else means the target
	# is an unquoted expansion
	if [[ $target != [\$\"\'\`]* && ! $target =~ $tgt_re ]]; then
		__gt_err "goto target $target is not a valid label name"
		printf '%16s%s\n' '' \
		    '(quote computed targets: goto "$var")' >&2
		return 0
	fi
	if [[ ${GOTO_STRICT-1} != 0 ]]; then
		guard='[[ $BASHPID == "$__GOTO_SHELL" ]]'
		guard+=" || __gt_fault $target; "
	fi
	local repl="{ __GOTO_RC=\$?; __GOTO_PC=$target;"
	repl+=" ${guard}continue $(( loops + 1 )); }"
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
	local fn_re='^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*'
	fn_re+='\(\)[[:space:]]*$'
	local kw_re='(^|[^A-Za-z0-9_])(goto|gosub|ret)([[:space:]]|$)'
	# the token pass reads space-separated records from __gt_tokens, so
	# it must not inherit a caller's IFS (`local` restores it on return)
	local IFS=$' \t\n'
	local body=$1 masked
	masked=$(__gt_mask "$body")

	local -a src mask
	mapfile -t src <<<"$body"
	mapfile -t mask <<<"$masked"

	local -a labels=() kind=() gtargets=() gsub_targets=() fns=()
	local -A seen=()
	local i loops=0 off len cmd tok errs=0 gsn=0

	# ---- scan -------------------------------------------------------
	for (( i = 0; i < ${#src[@]}; i++ )); do
		local ml=${mask[i]} sl=${src[i]} trimmed indent
		trimmed=${ml#"${ml%%[![:space:]]*}"}
		indent=$(( ${#ml} - ${#trimmed} ))
		kind[i]=CODE

		# track nested function definitions: canonical bash renders
		# them as `function f ()` / `{` / body / `};`, so the header's
		# indent identifies the closing brace
		if [[ $trimmed =~ $fn_re ]]; then
			fns+=("$indent")
			continue
		fi
		if (( ${#fns[@]} )) && [[ $trimmed == '}'* ]] &&
		    (( indent == fns[-1] )); then
			unset 'fns[-1]'
			continue
		fi

		# a `goto`/`ret`/`gosub` in a `...` substitution never reaches
		# the trampoline; the masker has hidden it, so check the raw
		# text and say so rather than compiling a silent no-op
		__gt_chk_backtick

		# a case pattern (`ret)`, `done|x)`) sits at the start of its
		# own line in canonical output but is data, not a command;
		# unbalanced closing parens are what distinguishes it
		if __gt_is_pattern; then
			continue
		fi

		__gt_classify && continue

		# walk the tokens for loop depth, goto/ret rewriting, and
		# stray break/continue detection
		local rewritten=$sl delta=0
		while read -r off len cmd tok; do
			(( cmd == 1 )) || continue
			case $tok in
			do) (( ++loops )) ;;
			done) (( loops > 0 )) && (( loops-- )) ;;
			break|continue) __gt_chk_stray ;;
			ret) __gt_rw_ret ;;
			goto) __gt_rw_goto ;;
			gosub) __gt_chk_gosub ;;
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

	# a label may not collide with a generated segment name, or the
	# dispatch would jump to the wrong arm (or loop forever)
	local lb
	for lb in "${labels[@]}"; do
		case $lb in
		__gt_*|__GOTO_*)
			__gt_err "label $lb uses the compiler's reserved" \
			    '__gt_/__GOTO_ namespace'
			;;
		esac
	done

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
	# emitted so that -E output runs on its own, without goto.sh
	printf '__gt_rc() { return "${1:-0}"; }\n'
	if (( gsn > 0 )); then
		printf 'declare -F __gt_ret > /dev/null || __gt_ret() {\n'
		printf '\tif (( ${#__GOTO_STACK[@]} == 0 )); then\n'
		printf '\t\tprintf %s >&2\n' \
		    "'goto: ret with empty gosub stack\\n'"
		printf '\t\texit 2\n\tfi\n'
		printf '\t__GOTO_PC=${__GOTO_STACK[-1]}\n'
		printf '\tunset %s\n}\n' "'__GOTO_STACK[-1]'"
	fi
	if [[ ${GOTO_STRICT-1} != 0 ]]; then
		local fmt="'goto: fatal: \`goto %s\` executed in a subshell"
		fmt+=" or pipeline (pid %s != %s)\\n'"
		printf 'declare -F __gt_fault > /dev/null || __gt_fault() {\n'
		printf '\tprintf %s "$1" "$BASHPID" "$__GOTO_SHELL" >&2\n' \
		    "$fmt"
		printf '\tkill -0 "$__GOTO_SHELL" 2>/dev/null &&\n'
		printf '\t    kill -s TERM "$__GOTO_SHELL" 2>/dev/null\n'
		printf '\texit 70\n}\n'
	fi
	printf 'while :; do\n  case $__GOTO_PC in\n'
	for (( i = 0; i < ${#names[@]}; i++ )); do
		next=__gt_END
		(( i + 1 < ${#names[@]} )) && next=${names[i+1]}
		printf '    (%s)\n      __GOTO_PC=%s\n' "${names[i]}" "$next"
		# restore the status the previous segment ended with, so a
		# label boundary is transparent to `$?`.  The common case
		# (status 0) costs one arithmetic test and no function
		# call.  Skipped under errexit, where re-raising a failure
		# here would exit a program plain bash would have kept
		# running.
		printf '      (( __GOTO_RC == 0 )) ||'
		printf ' { [[ $- == *e* ]] || __gt_rc "$__GOTO_RC"; }\n'
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
	local src parsed rc=0 restore=''
	# the scanner matches keywords with `case` and `[[ =~ ]]`, both of
	# which honour nocasematch; a caller that left it on would turn a
	# user's `Label`/`Do` command into compiler syntax
	if shopt -q nocasematch; then
		restore=1
		shopt -u nocasematch
	fi
	if (( $# )); then
		if [[ -d $1 ]]; then
			printf 'goto.sh: %s is a directory\n' "$1" >&2
			[[ -n $restore ]] && shopt -s nocasematch
			return 2
		fi
		if [[ ! -r $1 ]]; then
			printf 'goto.sh: cannot read %s\n' "$1" >&2
			[[ -n $restore ]] && shopt -s nocasematch
			return 2
		fi
		src=$(__gt_pass0 < "$1")
	else
		src=$(__gt_pass0)
	fi
	if parsed=$(__gt_pass1 "$src"); then
		__gt_compile_body "$parsed" || rc=$?
	else
		rc=$?
	fi
	[[ -n $restore ]] && shopt -s nocasematch
	return $rc
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
	if [[ ${1-} != --lib ]] && (( ${#FUNCNAME[@]} > 0 )); then
		# sourced from inside a function: the remainder of the file
		# is not a program we can take over, and compiling from the
		# `source` line would re-enter this function forever
		printf 'goto.sh: `source goto.sh` must be at the top level' >&2
		printf ' of a script,\n        not inside a function\n' >&2
		__gt_refuse
		return $?
	fi
	if [[ ${1-} != --lib ]] && (( ${#BASH_SOURCE[@]} > 1 )) &&
	    [[ ! -r ${BASH_SOURCE[1]} ]]; then
		# a script fed on stdin (`cat prog.sh | bash`) has no file
		# for us to read the rest of the program from, so a jump
		# would silently never be compiled
		printf 'goto.sh: cannot read the calling script (%s)\n' \
		    "${BASH_SOURCE[1]:-stdin}" >&2
		printf '        `source goto.sh` needs a real file: run\n' >&2
		printf '        `bash prog.sh`, not `cat prog.sh | bash`\n' >&2
		__gt_refuse
		return $?
	fi
	if [[ ${1-} != --lib ]] && (( ${#BASH_SOURCE[@]} == 1 )); then
		printf 'goto.sh: `source goto.sh` was not called from a' >&2
		printf ' script\n        (use --lib for the compiler API'  >&2
		printf ' alone)\n' >&2
		__gt_refuse
		return $?
	fi
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
