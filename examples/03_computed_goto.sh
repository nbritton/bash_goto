#!/usr/bin/env bash
# The pc is a string and dispatch is a 'case', so computed gotos are free.
here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=/dev/null
source "$here/../goto.sh"

input='aab'
pos=0
state=S0

label dispatch
c=${input:pos:1}
(( pos++ ))
[[ -z $c ]] && goto halt
goto "state_$state"                     # <-- computed goto

label state_S0
echo "S0 saw '$c'"
state=S1
goto dispatch

label state_S1
echo "S1 saw '$c'"
state=S0
goto dispatch

label halt
echo "halted in $state after $(( pos - 1 )) chars"
