#!/usr/bin/env bash
# shellcheck disable=SC2016
# (test strings quote emitted messages that contain literal ` and $)
# t06_regression.sh - pinned behavior: emitted code against golden files,
# runtime guards, and regression cases for fixed bugs.
#
# test/fixtures/orig_examples/ are byte-frozen copies of the pre-1.0
# example sources (4-space style, dirname preamble): style-variant inputs
# that pin code generation from a second angle.  Their emissions in
# golden/emit_fixture_*.txt regenerate via gen_golden.sh like the rest.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
rootabs=$(cd "$root" && pwd) || exit 1

tmp=$(mktemp -d "${TMPDIR:-/tmp}/goto-t.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- code generation is stable --------------------------------------------
for n in 01 02 03 04 05; do
	ex=("$root/examples/${n}_"*.sh)
	t_run bash "$root/goto.sh" -E "${ex[0]}"
	t_rc "emit $n compiles" 0 "$t_status"
	t_diff "emit $n matches golden" "golden/emit_$n.txt" "$t_out"
done

for n in 01 02 03 04 05; do
	fx=("fixtures/orig_examples/${n}_"*.sh)
	t_run bash "$root/goto.sh" -E "${fx[0]}"
	t_diff "fixture example $n emission is stable" \
	    "golden/emit_fixture_$n.txt" "$t_out"
done

# --- the -E output of a plain program runs standalone ---------------------
ex01=("$root/examples/01_"*.sh)
bash "$root/goto.sh" -E "${ex01[0]}" > "$tmp/standalone.sh"
t_run bash "$tmp/standalone.sh"
t_rc 'emitted trampoline runs standalone' 0 "$t_status"
t_diff 'emitted trampoline output matches the example golden' \
	'golden/01.out' "$t_out"

# --- runtime subshell/pipeline guard --------------------------------------
printf 'echo before\ngoto target | cat\nlabel target\necho after\n' \
	> "$tmp/pipe.sh"
t_run bash "$root/goto.sh" "$tmp/pipe.sh"
if (( t_status != 0 )); then
	t_ok "goto in a pipeline dies nonzero (got $t_status)"
else
	t_not_ok 'goto in a pipeline dies nonzero'
fi
t_like 'pipeline guard message names the goto' "$t_err" \
	'goto: fatal: `goto target` executed in a subshell or pipeline'
t_is 'pipeline guard fires before the jump' "$t_out" 'before'

# the guard's own exit status is 70; the parent normally reports 143
# because the guard SIGTERMs it, so ignore TERM to observe 70 directly
t_run bash -c "source '$rootabs/goto.sh' --lib
trap '' TERM
__GOTO_SHELL=\$\$
__gt_fault demo"
t_rc '__gt_fault exits 70 as the man page documents' 70 "$t_status"

t_run env GOTO_STRICT=0 bash "$root/goto.sh" "$tmp/pipe.sh"
t_rc 'GOTO_STRICT=0 disables the guard' 0 "$t_status"
t_is 'GOTO_STRICT=0 lets the program fall through' "$t_out" \
	$'before\nafter'

# --- computed goto misses are a run-time error ----------------------------
printf 'dest=missing\ngoto "$dest"\nlabel real\necho done\n' > "$tmp/c.sh"
t_run bash "$root/goto.sh" "$tmp/c.sh"
t_rc 'computed goto to a missing label exits 2' 2 "$t_status"
t_like 'computed goto miss names the label' "$t_err" \
	'goto: no such label: missing'

# --- regression: multi-line single-quoted strings (bug fixed) -------------
# the v1 masker dropped the newline inside '...', desynchronizing the
# mask/source line arrays and rewriting the wrong line
t_run bash "$root/goto.sh" fixtures/multiline_sq.sh
t_rc 'multi-line single-quoted string compiles and runs' 0 "$t_status"
t_is 'multi-line single-quoted string output' "$t_out" \
	$'first line\nsecond line\nok-after-multiline-sq'

# --- regression: herestrings (bug fixed) ----------------------------------
# the v1 masker treated <<< as a heredoc opener and masked the rest of
# the program away (labels silently ignored, gotos left uncompiled)
printf 'read -r a b <<< "alpha beta"\necho "a=$a b=$b"\ngoto fin\n' \
	> "$tmp/hs.sh"
printf 'echo unreached\nlabel fin\necho ok-herestring\n' >> "$tmp/hs.sh"
t_run bash "$root/goto.sh" "$tmp/hs.sh"
t_rc 'herestring program compiles and runs' 0 "$t_status"
t_is 'herestring program output' "$t_out" \
	$'a=alpha b=beta\nok-herestring'

# --- regression: literal __GOTO_PC= text in a string (bug fixed) ----------
# v1 validated goto targets by grepping the rewritten source, so a
# program merely *printing* __GOTO_PC=... was rejected as an undefined
# label; targets are now collected during the rewrite itself
printf 'echo "__GOTO_PC=zzz"\ngoto fin\nlabel fin\necho ok\n' \
	> "$tmp/lit.sh"
t_run bash "$root/goto.sh" "$tmp/lit.sh"
t_rc 'literal __GOTO_PC= string compiles' 0 "$t_status"
t_is 'literal __GOTO_PC= string runs' "$t_out" $'__GOTO_PC=zzz\nok'

# --- goto inside $( ) is a clear compile error ----------------------------
printf 'x=$(goto lbl)\nlabel lbl\necho hi\n' > "$tmp/csub.sh"
t_run bash "$root/goto.sh" "$tmp/csub.sh"
t_rc 'goto inside $( ) is rejected at compile time' 2 "$t_status"
t_like 'goto inside $( ) explains the subshell problem' "$t_err" \
	'cannot cross a subshell'

# --- 1.0.1 regressions: silent miscompiles found by the 1.0.1 audit -------
# a left shift is not a heredoc: v1.0.0 masked the rest of the program
# away here, so labels vanished and gotos were left uncompiled
printf 'i=0\nlabel top\n(( i++ ))\n(( bit = 1 << i ))\n' > "$tmp/sh1.sh"
printf 'echo "bit=$bit"\n(( i < 3 )) && goto top\necho end\n' >> "$tmp/sh1.sh"
t_run bash "$root/goto.sh" "$tmp/sh1.sh"
t_rc '`<<` inside (( )) is a shift, not a heredoc' 0 "$t_status"
t_is 'left-shift program runs to completion' "$t_out" \
	$'bit=2\nbit=4\nbit=8\nend'

# shell keywords used as for-loop words are data, not commands
kw_words=(goto break continue 'do' 'done' ret gosub)
for kw in "${kw_words[@]}"; do
	printf 'for __v in %s x; do\necho "w=$__v"\ndone\n' "$kw" \
	    > "$tmp/w.sh"
	printf 'goto z\nlabel z\necho end\n' >> "$tmp/w.sh"
	t_run bash "$root/goto.sh" "$tmp/w.sh"
	t_is "\`$kw\` as a for-loop word is data" "$t_out" \
	    "w=$kw"$'\nw=x\nend'
done

# a `done` in a word list must not unbalance the loop-depth count, or the
# emitted `continue N` escapes the wrong number of loops
printf 'for a in 1; do\nfor i in done; do\necho "inner $i"\n' > "$tmp/dp.sh"
printf 'goto out\ndone\ndone\necho NOPE\nlabel out\necho out\n' \
	>> "$tmp/dp.sh"
t_run bash "$root/goto.sh" "$tmp/dp.sh"
t_is 'loop depth survives `done` as data' "$t_out" $'inner done\nout'

# case patterns are data too, including ones that used to miscompile
printf 'x=ret\ncase $x in\nret) echo matched ;;\n*) echo other ;;\nesac\n' \
	> "$tmp/cp.sh"
t_run bash "$root/goto.sh" "$tmp/cp.sh"
t_is 'a `ret)` case pattern compiles and matches' "$t_out" 'matched'

# the caller's IFS must not disable the token scan
printf '#!/usr/bin/env bash\nIFS=:\nsource "%s"\n' "$rootabs/goto.sh" \
	> "$tmp/ifs.sh"
printf 'echo A\ngoto L\necho NEVER\nlabel L\necho B\n' >> "$tmp/ifs.sh"
t_run bash "$tmp/ifs.sh"
t_is 'a caller IFS does not disable compilation' "$t_out" $'A\nB'

# nor may nocasematch turn a user command into compiler syntax
printf '#!/usr/bin/env bash\nshopt -s nocasematch\nsource "%s"\n' \
	"$rootabs/goto.sh" > "$tmp/nc.sh"
printf 'Label() { echo "Label ran"; }\necho A\nLabel thing\n' >> "$tmp/nc.sh"
printf 'label L\necho B\n' >> "$tmp/nc.sh"
t_run bash "$tmp/nc.sh"
t_is 'nocasematch does not corrupt the scanner' "$t_out" \
	$'A\nLabel ran\nB'

# a source line that merely *contains* goto.sh must survive pass 0
printf 'LIBVAR=loaded\n' > "$tmp/lib_nogoto.sh"
printf 'echo start\nsource %s/lib_nogoto.sh\n' "$tmp" > "$tmp/srp.sh"
printf 'echo "v=$LIBVAR"\ngoto e\nlabel e\necho end\n' >> "$tmp/srp.sh"
t_run bash "$root/goto.sh" "$tmp/srp.sh"
t_is 'only a real goto.sh preamble line is dropped' "$t_out" \
	$'start\nv=loaded\nend'

# pass 0 must not rewrite comment labels inside a heredoc body
printf 'cat <<%s\n# label not_a_label\nsource goto.sh\nEOF\n' "'EOF'" \
	> "$tmp/hd0.sh"
printf 'echo A\nlabel L\necho B\n' >> "$tmp/hd0.sh"
t_run bash "$root/goto.sh" "$tmp/hd0.sh"
t_is 'heredoc bodies survive the comment-label sugar' "$t_out" \
	$'# label not_a_label\nsource goto.sh\nA\nB'

# quoted `<<` text is not a heredoc opener in pass 0
printf 'echo "<<EOF"\ngoto L\n#: L\necho reached\n' > "$tmp/qhd.sh"
t_run bash "$root/goto.sh" "$tmp/qhd.sh"
t_is 'quoted << text cannot hide a later comment label' "$t_out" \
	$'<<EOF\nreached'

# every heredoc on a command line is queued and masked in source order
printf 'cat <<A <<B\nfirst\nA\ngoto NOPE\nlabel PHANTOM\n' \
	> "$tmp/mhd.sh"
printf 'second\nB\ngoto REAL\necho NEVER\nlabel REAL\necho landed\n' \
	>> "$tmp/mhd.sh"
t_run bash "$root/goto.sh" "$tmp/mhd.sh"
t_rc 'multiple heredocs compile without scanning their bodies' 0 "$t_status"
t_is 'multiple heredoc bodies remain data' "$t_out" \
	$'goto NOPE\nlabel PHANTOM\nsecond\nlanded'

printf "cat <<'END DOC'\ngoto NOPE\nlabel PHANTOM\nEND DOC\n" \
	> "$tmp/qdelim.sh"
printf 'goto REAL\necho NEVER\nlabel REAL\necho landed\n' \
	>> "$tmp/qdelim.sh"
t_run bash "$root/goto.sh" "$tmp/qdelim.sh"
t_is 'a quoted heredoc delimiter may contain spaces' "$t_out" \
	$'goto NOPE\nlabel PHANTOM\nlanded'

# a whole-line comment-looking string inside a multiline quote is data
printf "%s\n" "echo 'first" '#: not_a_label' "last'" \
	> "$tmp/mlq.sh"
printf 'goto L\n#: L\necho landed\n' >> "$tmp/mlq.sh"
t_run bash "$root/goto.sh" "$tmp/mlq.sh"
t_is 'pass 0 respects multiline quote state' "$t_out" \
	$'first\n#: not_a_label\nlast\nlanded'

# an empty or comment-only program is a valid (empty) program
: > "$tmp/empty.sh"
t_run bash "$root/goto.sh" "$tmp/empty.sh"
t_rc 'an empty program compiles and runs' 0 "$t_status"
printf '#!/usr/bin/env bash\n# nothing here\n' > "$tmp/cmt.sh"
t_run bash "$root/goto.sh" "$tmp/cmt.sh"
t_rc 'a comment-only program compiles and runs' 0 "$t_status"

# --- $? is transparent across a label boundary (new in 1.0.1) ------------
printf 'false\nlabel after\necho "status=$?"\n' > "$tmp/q1.sh"
t_run bash "$root/goto.sh" "$tmp/q1.sh"
t_is 'a label boundary preserves $?' "$t_out" 'status=1'

printf 'false\ngoto x\nlabel x\necho "status=$?"\n' > "$tmp/q2.sh"
t_run bash "$root/goto.sh" "$tmp/q2.sh"
t_is 'a goto preserves $?' "$t_out" 'status=1'

printf 'set -e\nfalse || goto x\necho NOPE\nlabel x\necho survived\n' \
	> "$tmp/q3.sh"
t_run bash "$root/goto.sh" "$tmp/q3.sh"
t_rc 'restoring $? never trips the program errexit' 0 "$t_status"
t_is 'errexit program survives a || goto' "$t_out" 'survived'

# reserved words put their condition in command position.  Before 1.0.2,
# these gotos survived compilation and called the runtime stub instead.
printf 'if goto L; then\necho NEVER\nfi\necho NEVER2\n' > "$tmp/ifg.sh"
printf 'label L\necho landed\n' >> "$tmp/ifg.sh"
t_run bash "$root/goto.sh" "$tmp/ifg.sh"
t_is 'goto in an if condition jumps' "$t_out" 'landed'

printf 'while goto L; do\necho NEVER\ndone\necho NEVER2\n' \
	> "$tmp/whg.sh"
printf 'label L\necho landed\n' >> "$tmp/whg.sh"
t_run bash "$root/goto.sh" "$tmp/whg.sh"
t_is 'goto in a while condition escapes the loop and trampoline' \
	"$t_out" 'landed'

# arithmetic identifiers are data even when they use compiler keywords
printf '(( goto = 1 ))\necho "$goto"\nx=$(( goto + 2 ))\n' \
	> "$tmp/arithword.sh"
printf 'echo "$x"\ngoto L\nlabel L\necho landed\n' \
	>> "$tmp/arithword.sh"
t_run bash "$root/goto.sh" "$tmp/arithword.sh"
t_is 'compiler keywords remain valid arithmetic variable names' "$t_out" \
	$'1\n3\nlanded'

# array-assignment elements are words even when named like compiler syntax
printf 'words=(goto L done)\nprintf "%%s\\n" "${words[*]}"\n' \
	> "$tmp/arrayword.sh"
printf 'goto REAL\nlabel REAL\necho landed\n' >> "$tmp/arrayword.sh"
t_run bash "$root/goto.sh" "$tmp/arrayword.sh"
t_is 'compiler keywords remain valid array elements' "$t_out" \
	$'goto L done\nlanded'

# extglob groups are patterns, and their alternatives are data
printf 'echo @(goto|done)\ngoto REAL\nlabel REAL\necho landed\n' \
	> "$tmp/extglob.sh"
t_run bash -O extglob "$root/goto.sh" "$tmp/extglob.sh"
t_is 'compiler keywords remain valid extglob alternatives' "$t_out" \
	$'@(goto|done)\nlanded'

# parentheses and boolean operators inside [[ ]] do not start commands
printf 'if [[ ( goto == goto && done == done ) ]]; then\n' \
	> "$tmp/condword.sh"
printf 'echo yes\nfi\ngoto L\nlabel L\necho landed\n' \
	>> "$tmp/condword.sh"
t_run bash "$root/goto.sh" "$tmp/condword.sh"
t_is 'compiler keywords remain valid [[ expression operands' "$t_out" \
	$'yes\nlanded'

# `time -p` accepts an option before its command word
printf 'time -p goto L\necho NEVER\nlabel L\necho landed\n' \
	> "$tmp/timep.sh"
t_run bash "$root/goto.sh" "$tmp/timep.sh"
t_is 'goto after time -p is still in command position' "$t_out" \
	'landed'

# --- emitted code stands alone, including gosub/ret ----------------------
ex04=("$root/examples/04_"*.sh)
bash "$root/goto.sh" -E "${ex04[0]}" > "$tmp/sa.sh"
t_run bash "$tmp/sa.sh"
t_rc 'emitted gosub program runs standalone' 0 "$t_status"
t_diff 'standalone gosub output matches the example golden' \
	'golden/04.out' "$t_out"

# --- exit-status propagation (new in 1.0) ---------------------------------
printf 'goto e\nlabel e\ntrue\n' > "$tmp/s0.sh"
t_run bash "$root/goto.sh" "$tmp/s0.sh"
t_rc 'succeeding final command exits 0' 0 "$t_status"

printf 'goto e\nlabel e\nfalse\n' > "$tmp/s1.sh"
t_run bash "$root/goto.sh" "$tmp/s1.sh"
t_rc 'failing final command exits 1' 1 "$t_status"

printf 'false\nlabel tail\n' > "$tmp/s2.sh"
t_run bash "$root/goto.sh" "$tmp/s2.sh"
t_rc 'empty tail segment preserves the last real status' 1 "$t_status"

printf 'label e\nfalse && goto e\n' > "$tmp/s3.sh"
t_run bash "$root/goto.sh" "$tmp/s3.sh"
t_rc 'untaken conditional goto propagates the test status' 1 "$t_status"

printf 'goto e\nlabel e\nexit 7\n' > "$tmp/s4.sh"
t_run bash "$root/goto.sh" "$tmp/s4.sh"
t_rc 'explicit exit still wins' 7 "$t_status"

t_done
