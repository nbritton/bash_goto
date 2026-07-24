#!/usr/bin/env bash
# The OTHER runtime.  No compiler pass -- DEBUG-trap longjmp + tail-eval.
# This can do the one thing goto.sh cannot: jump out of a called function.
here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=/dev/null
source "$here/../goto_trap.sh"

echo line 1
goto skip
echo "never printed"
label skip
echo line 3

helper() {
	local d=$1
	echo "  helper depth $d"
	(( d > 2 )) && goto after_helper    # unwinds 3 function frames
	helper $(( d + 1 ))
}
helper 1
echo "not reached"

label after_helper
echo "longjmp'd out of a recursive function"
