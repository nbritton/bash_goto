#!/usr/bin/env bash
# t03_unit.sh - unit tests for the individual compiler passes.
#
# goto.sh is sourced with --lib, which defines the passes without taking
# over this file; the __gt_* functions are private but unit-tested here
# on purpose (they are the compiler).

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
rootabs=$(cd "$root" && pwd) || exit 1
# shellcheck source=/dev/null
source "$root/goto.sh" --lib

# --- pass 0: acquisition + comment-label sugar ----------------------------
got=$(__gt_pass0 <<<$'#!/usr/bin/env bash\necho hi')
t_is 'pass0: shebang becomes a blank line' "$got" $'\necho hi'

got=$(__gt_pass0 <<<$'source ../goto.sh\necho hi')
t_is 'pass0: source goto.sh line is dropped' "$got" $'\necho hi'

got=$(__gt_pass0 <<<$'. /somewhere/goto_trap.sh\necho hi')
t_is 'pass0: dot-source goto_trap.sh line is dropped' "$got" $'\necho hi'

got=$(__gt_pass0 <<<'# label foo')
t_is 'pass0: "# label foo" becomes "label foo"' "$got" 'label foo'

got=$(__gt_pass0 <<<'#: bar')
t_is 'pass0: "#: bar" becomes "label bar"' "$got" 'label bar'

got=$(__gt_pass0 <<<'#label baz')
t_is 'pass0: "#label baz" (no space) becomes "label baz"' "$got" \
	'label baz'

got=$(__gt_pass0 <<<'  #  label  spaced  ')
t_is 'pass0: whitespace variants normalize' "$got" 'label spaced'

got=$(__gt_pass0 <<<'echo # label not_first_word')
t_is 'pass0: label sugar only when the comment is the whole line' \
	"$got" 'echo # label not_first_word'

got=$(__gt_pass0 < <(printf 'no trailing newline'))
t_is 'pass0: unterminated final line is kept' "$got" 'no trailing newline'

# --- pass 2: masking ------------------------------------------------------
mask_in=()
mask_want=()
mask_desc=()

mask_desc+=('double and single quoted text is masked')
mask_in+=("echo \"a b\" 'c d'")
mask_want+=("echo \"XXX\" 'XXX'")

mask_desc+=('newline inside single quotes keeps lines aligned')
mask_in+=($'x=\'a\nb\'\ny=2')
mask_want+=($'x=\'X\nX\'\ny=2')

mask_desc+=('herestring <<< does not open a heredoc')
mask_in+=($'read x <<< "v w"\necho done')
mask_want+=($'read x <<< "XXX"\necho done')

mask_desc+=('heredoc body and delimiter line are masked')
mask_in+=($'cat <<EOF\ngoto nowhere\nEOF\necho after')
mask_want+=($'cat <<EOF\nXXXXXXXXXXXX\nXXX\necho after')

mask_desc+=('escaped quote inside double quotes')
mask_in+=('echo "a\"b"')
mask_want+=('echo "XXXX"')

mask_desc+=('<<- strips leading tabs when matching the delimiter')
mask_in+=($'cat <<-EOF\n\tbody\n\tEOF\nnext')
mask_want+=($'cat <<-EOF\nXXXXX\nXXXX\nnext')

mask_desc+=('quoted heredoc delimiter')
mask_in+=($'cat <<\'EOF\'\nstuff\nEOF\nafter')
mask_want+=($'cat <<\'XXX\'\nXXXXX\nXXX\nafter')

for (( m = 0; m < ${#mask_in[@]}; m++ )); do
	got=$(__gt_mask "${mask_in[m]}")
	t_is "mask: ${mask_desc[m]}" "$got" "${mask_want[m]}"
	if (( ${#got} == ${#mask_in[m]} )); then
		t_ok "mask: length preserved (${mask_desc[m]})"
	else
		t_not_ok "mask: length preserved (${mask_desc[m]})" \
		    "got ${#got}, want ${#mask_in[m]}"
	fi
done

# --- tokenizer ------------------------------------------------------------
got=$(__gt_tokens 'if true; then')
t_is 'tokens: if true; then' "$got" \
	$'0 2 1 if\n3 4 0 true\n7 1 0 ;\n9 4 1 then'

got=$(__gt_tokens 'echo do')
t_is 'tokens: "do" as an argument is not command position' "$got" \
	$'0 4 1 echo\n5 2 0 do'

got=$(__gt_tokens 'a && b')
t_is 'tokens: && resets command position' "$got" \
	$'0 1 1 a\n2 2 0 &&\n5 1 1 b'

got=$(__gt_tokens '(x)')
t_is 'tokens: parens delimit and reset command position' "$got" \
	$'0 1 0 (\n1 1 1 x\n2 1 0 )'

# --- pass 1: parse via bash + declare -f ----------------------------------
got=$(__gt_pass1 'echo    hi')
t_like 'pass1: output is canonicalized (spaces squeezed)' "$got" \
	'    echo hi'

alias __t03_macro='echo expanded-by-alias'
got=$(__gt_pass1 '__t03_macro')
unalias __t03_macro
t_like 'pass1: aliases expand at parse time (macro machinery)' "$got" \
	'echo expanded-by-alias'

t_run bash -c "source '$rootabs/goto.sh' --lib; __gt_pass1 'if then fi'"
t_rc 'pass1: syntax error returns 2' 2 "$t_status"
t_like 'pass1: syntax error is reported' "$t_err" \
	'goto.sh: syntax error in program:'
t_like 'pass1: bash detail lines are indented below the header' "$t_err" \
	$'\n  '

# --- compile_body: minimal program ----------------------------------------
got=$(__gt_compile_body '    echo hi')
t_like 'compile: entry segment is emitted' "$got" '(__gt_entry)'
t_like 'compile: entry falls through to END' "$got" '__GOTO_PC=__gt_END'
t_like 'compile: banner counts labels and segments' "$got" \
	'0 label(s), 1 segment(s)'

# --- runtime helpers ------------------------------------------------------
t_run bash -c "source '$rootabs/goto.sh' --lib; __gt_ret"
t_rc 'ret with empty gosub stack exits 2' 2 "$t_status"
t_like 'ret with empty gosub stack says so' "$t_err" \
	'goto: ret with empty gosub stack'

t_run bash -c "source '$rootabs/goto.sh' --lib
__GOTO_STACK=(aa bb)
__gt_ret
printf '%s %s\n' \"\$__GOTO_PC\" \"\${#__GOTO_STACK[@]}\""
t_is 'ret pops the top of the gosub stack' "$t_out" 'bb 1'

t_done
