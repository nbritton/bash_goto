#!/usr/bin/env bash
# Aliases defined BEFORE the source line are expanded by bash's own parser
# during pass 1, so they behave like C preprocessor macros over goto.
shopt -s expand_aliases
alias INC='(( count++ ))'
alias REPEAT_WHILE_UNDER='(( count < 3 )) && goto'
here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=/dev/null
source "$here/../goto.sh"

count=0
label loop
INC
REPEAT_WHILE_UNDER loop
echo "count=$count"
echo "(run with GOTO_EMIT=1 to see what the macros compiled to)"
