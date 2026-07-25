#!/usr/bin/env bash
# t01_sanity.sh - environment and repo sanity checks.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..

# --- interpreter ----------------------------------------------------------
if (( BASH_VERSINFO[0] >= 5 )); then
	t_ok "bash major version >= 5 (${BASH_VERSION})"
else
	t_not_ok "bash major version >= 5 (got ${BASH_VERSION})"
fi

# --- repo layout ----------------------------------------------------------
for f in goto.sh goto_trap.sh README.md bash-style-guide.md \
	examples/01_forward_and_backward.sh examples/02_nested_escape.sh \
	examples/03_computed_goto.sh examples/04_gosub.sh \
	examples/05_macros.sh examples/06_longjmp_from_function.sh; do
	if [[ -r $root/$f ]]; then
		t_ok "exists and readable: $f"
	else
		t_not_ok "exists and readable: $f"
	fi
done

# --- every script parses --------------------------------------------------
for f in "$root"/goto.sh "$root"/goto_trap.sh "$root"/examples/*.sh \
	./*.sh; do
	if bash -n "$f" 2> /dev/null; then
		t_ok "bash -n ${f#"$root"/}"
	else
		t_not_ok "bash -n ${f#"$root"/}"
	fi
done

# --- executable bits (a lost file mode breaks shebang-interpreter use) -----
for f in "$root"/goto.sh "$root"/goto_trap.sh "$root"/examples/*.sh \
	./run_tests.sh; do
	if [[ -x $f ]]; then
		t_ok "executable: ${f#"$root"/}"
	else
		t_not_ok "executable: ${f#"$root"/}"
	fi
done

# --- library mode ---------------------------------------------------------
t_run bash -c "source '$root/goto.sh' --lib
declare -F goto_compile > /dev/null || exit 3
declare -F goto_run > /dev/null || exit 4
echo lib-ok"
t_rc 'source goto.sh --lib returns to caller' 0 "$t_status"
t_is 'source goto.sh --lib defines the public functions' "$t_out" 'lib-ok'

# --- uncompiled runtime stubs ---------------------------------------------
t_run bash -c "source '$root/goto.sh' --lib; label anything"
t_rc 'label stub is a no-op' 0 "$t_status"
t_run bash -c "source '$root/goto.sh' --lib; goto somewhere"
t_rc 'goto stub returns 127' 127 "$t_status"
t_like 'goto stub explains the program was not compiled' "$t_err" \
	'somewhere: program was not compiled by goto.sh'
t_run bash -c "source '$root/goto.sh' --lib; gosub somewhere"
t_rc 'gosub stub returns 127' 127 "$t_status"
t_run bash -c "source '$root/goto.sh' --lib; ret"
t_rc 'ret stub returns 127' 127 "$t_status"

# --- help -----------------------------------------------------------------
t_run bash "$root/goto.sh" -h
t_rc 'goto.sh -h exits 0' 0 "$t_status"
t_like 'goto.sh -h shows usage' "$t_out" 'Usage'
t_like 'goto.sh -h shows the environment knobs' "$t_out" 'GOTO_EMIT'

# --- sourcing from a non-bash shell must not kill it -----------------------
if command -v zsh > /dev/null; then
	t_run zsh -c "source '$root/goto.sh'; echo \"alive rc=\$?\""
	t_like 'sourcing from zsh refuses politely' "$t_err" \
	    'this is a bash tool'
	t_is 'sourcing from zsh leaves the shell alive' "$t_out" \
	    'alive rc=2'
	t_run zsh -c "source '$root/goto_trap.sh'; echo \"alive rc=\$?\""
	t_is 'sourcing goto_trap from zsh leaves the shell alive' \
	    "$t_out" 'alive rc=2'
else
	t_ok 'zsh not installed here - zsh guard check skipped'
	t_ok 'zsh not installed here - zsh guard check skipped (alive)'
	t_ok 'zsh not installed here - zsh guard check skipped (trap)'
fi

# --- version is authored in exactly one place ------------------------------
# __GT_VERSION in goto.sh is the single source of truth; every other copy
# is checked against it here, so a release bump cannot half-land
gt_ver=''
while IFS= read -r vline; do
	if [[ $vline =~ ^__GT_VERSION=\'([0-9]+\.[0-9]+\.[0-9]+)\'$ ]]; then
		gt_ver=${BASH_REMATCH[1]}
		break
	fi
done < "$root/goto.sh"
if [[ -n $gt_ver ]]; then
	t_ok "__GT_VERSION is set in goto.sh ($gt_ver)"
else
	t_not_ok '__GT_VERSION is set in goto.sh'
fi

t_run bash "$root/goto.sh" -V
t_rc 'goto.sh -V exits 0' 0 "$t_status"
t_is 'goto.sh -V prints name and version' "$t_out" "goto.sh $gt_ver"
t_run bash "$root/goto.sh" --version
t_is 'goto.sh --version matches -V' "$t_out" "goto.sh $gt_ver"

th_line=''
while IFS= read -r vline; do
	if [[ $vline == .TH\ * ]]; then
		th_line=$vline
		break
	fi
done < "$root/man/goto.sh.1"
th_re='^\.TH "GOTO\.SH" "1" "([^"]*)" "goto\.sh ([^"]*)" "[^"]*"$'
if [[ $th_line =~ $th_re ]]; then
	th_date=${BASH_REMATCH[1]}
	t_is 'the man page .TH version matches __GT_VERSION' \
	    "${BASH_REMATCH[2]}" "$gt_ver"
else
	t_not_ok 'the man page .TH line is well formed' "got: ${th_line@Q}"
	t_not_ok 'the man page .TH version matches __GT_VERSION'
fi

cl_ver=''
cl_date=''
cl_re='^##\ \[([0-9.]+)\]\ -\ ([0-9]{4}-[0-9]{2}-[0-9]{2})$'
while IFS= read -r vline; do
	if [[ $vline =~ $cl_re ]]; then
		cl_ver=${BASH_REMATCH[1]}
		cl_date=${BASH_REMATCH[2]}
		break
	fi
done < "$root/CHANGELOG.md"
t_is 'the newest CHANGELOG release matches __GT_VERSION' "$cl_ver" "$gt_ver"
t_is 'the man page .TH date matches the CHANGELOG release date' \
	"$th_date" "$cl_date"

cl_ref=''
while IFS= read -r vline; do
	[[ $vline == "[$gt_ver]:"*"/tag/v$gt_ver" ]] && cl_ref=$vline
done < "$root/CHANGELOG.md"
if [[ -n $cl_ref ]]; then
	t_ok "the CHANGELOG carries a v$gt_ver tag link"
else
	t_not_ok "the CHANGELOG carries a v$gt_ver tag link"
fi

t_done
