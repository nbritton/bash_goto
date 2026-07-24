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

# --- version ---------------------------------------------------------------
t_run bash "$root/goto.sh" -V
t_rc 'goto.sh -V exits 0' 0 "$t_status"
t_is 'goto.sh -V prints name and version' "$t_out" 'goto.sh 1.0.0'
t_run bash "$root/goto.sh" --version
t_is 'goto.sh --version matches -V' "$t_out" 'goto.sh 1.0.0'

t_done
