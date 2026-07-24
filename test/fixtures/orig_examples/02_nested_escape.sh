#!/usr/bin/env bash
# goto out of arbitrarily nested loops / case / if.  The compiler counts the
# lexical loop depth and emits 'continue N' with the right N.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../goto.sh"

for a in 1 2 3; do
  for b in x y z; do
    echo "  $a$b"
    [[ $a$b == 2y ]] && goto out       # compiles to: continue 3
  done
done
echo "not reached"

label out
echo "escaped two nested loops"

i=0
label spin
while (( i < 9 )); do
  case $i in
    0|1|2) : $(( i++ ))
           if (( i < 3 )); then goto spin; else goto finished; fi ;;
    *)     break ;;
  esac
done
label finished
echo "out of case-inside-while-inside-if, i=$i"
