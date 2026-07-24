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

tmp=$(mktemp -d)
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
t_like 'goto inside $( ) explains the target problem' "$t_err" \
	'is not a valid label name'

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
