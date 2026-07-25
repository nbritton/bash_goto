#!/usr/bin/env bash
# t02_style.sh - static conformance checks against bash-style-guide.md.
#
# Scans all first-party sources (repo scripts, examples, and this test
# suite).  test/fixtures/ is excluded: fixtures preserve upstream
# formatting byte-for-byte on purpose.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
# the compiler's own masker blanks quoted text, so a pattern like
# `[ ` or a backtick inside a *string literal* is not mistaken for code
# shellcheck source=/dev/null
source "$root/goto.sh" --lib

files=("$root"/goto.sh "$root"/goto_trap.sh "$root"/examples/*.sh ./*.sh)

# expand tabs (tab stop 8) and return the display width in `width`
line_width() {
	local s=$1 i c
	width=0
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		if [[ $c == $'\t' ]]; then
			width=$(( width + 8 - width % 8 ))
		else
			(( ++width ))
		fi
	done
}

for f in "${files[@]}"; do
	name=${f#"$root"/}
	bad_shebang=''
	bad_width=''
	bad_indent=''
	bad_blank=''
	bad_trailing=''
	bad_bracket=''
	bad_backtick_sub=''
	bad_semi=''
	bad_kw=''
	blanks=0
	lineno=0
	while IFS= read -r line; do
		(( ++lineno ))
		if (( lineno == 1 )) &&
		    [[ $line != '#!/usr/bin/env bash' ]]; then
			bad_shebang=$lineno
		fi
		line_width "$line"
		if (( width > 80 )); then
			bad_width+=" $lineno"
		fi
		# indentation must be tabs, never spaces
		if [[ $line == ' '* ]]; then
			bad_indent+=" $lineno"
		fi
		# at most one blank line in a row
		if [[ -z $line ]]; then
			(( ++blanks ))
			(( blanks > 1 )) && bad_blank+=" $lineno"
		else
			blanks=0
		fi
		if [[ $line == *' ' || $line == *$'\t' ]]; then
			bad_trailing+=" $lineno"
		fi
		# skip pure comment lines for the code-pattern checks
		trimmed=${line#"${line%%[![:space:]]*}"}
		[[ $trimmed == '#'* ]] && continue
		# check the masked line so that quoted text cannot look
		# like code (this also exercises the masker itself)
		line=$(__gt_mask "$line")
		# a line marked POSIX must parse in a POSIX shell, where
		# [[ ]] does not exist
		[[ $line == *POSIX* ]] && continue
		# single-bracket test (allow [[ ... ]])
		if [[ $line =~ (^|[^\[])\[[[:space:]] ]]; then
			bad_bracket+=" $lineno"
		fi
		# backtick command substitution
		if [[ $line =~ =\`|\$\(\` ]]; then
			bad_backtick_sub+=" $lineno"
		fi
		# no trailing semicolon (case terminators ;; are fine)
		if [[ $line == *';' && $line != *';;' ]]; then
			bad_semi+=" $lineno"
		fi
		# banned words: function keyword, let, readonly, seq
		if [[ $line =~ ^[[:space:]]*function[[:space:]] ]] ||
		    [[ $line =~ (^|[[:space:]])(let|readonly)[[:space:]] ]] ||
		    [[ $line =~ (^|[[:space:]\$\(])seq[[:space:]] ]]; then
			bad_kw+=" $lineno"
		fi
	done < "$f"

	if [[ -z $bad_shebang ]]; then
		t_ok "$name: shebang is #!/usr/bin/env bash"
	else
		t_not_ok "$name: shebang is #!/usr/bin/env bash"
	fi
	if [[ -z $bad_width ]]; then
		t_ok "$name: no line exceeds 80 columns (tab=8)"
	else
		t_not_ok "$name: no line exceeds 80 columns" "lines:$bad_width"
	fi
	if [[ -z $bad_indent ]]; then
		t_ok "$name: indentation is tabs, not spaces"
	else
		t_not_ok "$name: indentation is tabs" "lines:$bad_indent"
	fi
	if [[ -z $bad_blank ]]; then
		t_ok "$name: no more than one blank line in a row"
	else
		t_not_ok "$name: blank line runs" "lines:$bad_blank"
	fi
	if [[ -z $bad_trailing ]]; then
		t_ok "$name: no trailing whitespace"
	else
		t_not_ok "$name: trailing whitespace" "lines:$bad_trailing"
	fi
	if [[ -z $bad_bracket ]]; then
		t_ok "$name: uses double-bracket tests only"
	else
		t_not_ok "$name: single-bracket test" "lines:$bad_bracket"
	fi
	if [[ -z $bad_backtick_sub ]]; then
		t_ok "$name: no backtick command substitution"
	else
		t_not_ok "$name: backtick substitution" \
		    "lines:$bad_backtick_sub"
	fi
	if [[ -z $bad_semi ]]; then
		t_ok "$name: no trailing semicolons"
	else
		t_not_ok "$name: trailing semicolons" "lines:$bad_semi"
	fi
	if [[ -z $bad_kw ]]; then
		t_ok "$name: no banned keywords (function/let/readonly/seq)"
	else
		t_not_ok "$name: banned keyword" "lines:$bad_kw"
	fi
done

# eval is permitted only in the two runtimes, where it is the mechanism
for f in "${files[@]}"; do
	name=${f#"$root"/}
	case $name in
	goto.sh|goto_trap.sh)
		continue
		;;
	esac
	hits=$(grep -cE '(^[[:space:]]*|\$\()eval[[:space:]]' "$f") || :
	if [[ ${hits:-0} == 0 ]]; then
		t_ok "$name: no eval outside the runtimes"
	else
		t_not_ok "$name: no eval outside the runtimes" "count: $hits"
	fi
done

# when shellcheck is installed, the whole tree must lint clean
if command -v shellcheck > /dev/null; then
	# same flags as `make lint`, so the two can never disagree
	t_run shellcheck -x -P SCRIPTDIR -S style "${files[@]}"
	t_rc 'shellcheck is clean on all sources' 0 "$t_status"
else
	t_ok 'shellcheck not installed here - skipped (advisory)'
fi

t_done
