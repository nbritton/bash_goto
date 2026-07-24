#!/usr/bin/env bash
# shellcheck disable=SC2016
# (test strings quote emitted messages that contain literal ` and $)
# t05_functional.sh - end-to-end behavior: the example programs, every
# invocation mode, and the language surface (sugar, masking inertness).

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
rootabs=$(cd "$root" && pwd) || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the six examples against their golden outputs ------------------------
for ex in "$root"/examples/0*.sh; do
	name=${ex##*/}
	num=${name%%_*}
	t_run bash "$ex"
	t_rc "example $name exits 0" 0 "$t_status"
	t_diff "example $name output matches golden" \
	    "golden/$num.out" "$t_out"
done

# --- invocation modes -----------------------------------------------------
t_run bash -c "printf 'echo one\ngoto z\necho hidden\nlabel z\necho two\n' \
	| bash '$rootabs/goto.sh'"
t_rc 'stdin mode exits 0' 0 "$t_status"
t_is 'stdin mode runs the program' "$t_out" $'one\ntwo'

printf 'echo "argc=$# argv=$*"\ngoto e\nlabel e\necho "arg1=$1"\n' \
	> "$tmp/args.sh"
t_run bash "$root/goto.sh" "$tmp/args.sh" alpha 'b c'
t_is 'file mode preserves "$@"' "$t_out" $'argc=2 argv=alpha b c\narg1=alpha'

printf '#!%s\necho via shebang\ngoto s\necho no\nlabel s\necho jumped\n' \
	"$rootabs/goto.sh" > "$tmp/sb.sh"
chmod +x "$tmp/sb.sh"
t_run "$tmp/sb.sh"
t_rc 'shebang-interpreter mode exits 0' 0 "$t_status"
t_is 'shebang-interpreter mode runs the program' "$t_out" \
	$'via shebang\njumped'

t_run bash fixtures/heredoc_form.sh "$rootabs"
t_rc 'heredoc form exits 0' 0 "$t_status"
t_is 'heredoc form runs in the current shell and returns' "$t_out" \
	$'in heredoc\nheredoc done\nback in the outer script'

printf 'goto e\nlabel e\nexit 7\n' > "$tmp/x7.sh"
t_run bash "$root/goto.sh" "$tmp/x7.sh"
t_rc 'program exit status is propagated' 7 "$t_status"

# since 1.0 the status of the program's last command propagates, like
# plain bash (previously masked to 0 by the trampoline)
printf 'goto e\nlabel e\nfalse\n' > "$tmp/f.sh"
t_run bash "$root/goto.sh" "$tmp/f.sh"
t_rc 'a failing final command propagates its status' 1 "$t_status"

t_run env GOTO_EMIT=1 bash "$root/goto.sh" "$tmp/x7.sh"
t_like 'GOTO_EMIT=1 prints the compiled program on stderr' "$t_err" \
	'# ---- compiled by goto.sh:'

# --- label sugar ----------------------------------------------------------
printf 'goto a\necho no\n# label a\necho A\ngoto b\necho no\n#: b\necho B\n' \
	> "$tmp/sugar.sh"
t_run bash "$root/goto.sh" "$tmp/sugar.sh"
t_is 'comment labels "# label a" and "#: b" both work' "$t_out" $'A\nB'

printf 'goto q\necho no\n#label q\necho got-q\n' > "$tmp/ns.sh"
t_run bash "$root/goto.sh" "$tmp/ns.sh"
t_is 'comment label with no space after # works' "$t_out" 'got-q'

# --- masking inertness ----------------------------------------------------
printf 'for i in 1; do echo done; done\n' > "$tmp/inert1.sh"
t_run bash "$root/goto.sh" "$tmp/inert1.sh"
t_is '"echo done" does not close a loop' "$t_out" 'done'

printf 'echo "label not-a-label"\necho ok\n' > "$tmp/inert2.sh"
t_run bash "$root/goto.sh" "$tmp/inert2.sh"
t_is 'the word label inside a string is inert' "$t_out" \
	$'label not-a-label\nok'

printf 'cat <<EOF\ngoto nowhere\nEOF\n' > "$tmp/inert3.sh"
t_run bash "$root/goto.sh" "$tmp/inert3.sh"
t_rc 'goto inside a heredoc body is inert (compiles)' 0 "$t_status"
t_is 'goto inside a heredoc body is inert (runs)' "$t_out" 'goto nowhere'

t_run bash "$root/goto.sh" fixtures/ansi_quote.sh
t_is 'ANSI-C quoting with an escaped quote is handled' "$t_out" \
	$'it\'s here\nok'

t_done
