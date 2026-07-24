#!/usr/bin/env bash
# gosub/ret: the compiler auto-generates a return label at each call site,
# splits the segment there, and keeps a real return stack.
here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=/dev/null
source "$here/../goto.sh"

n=3
gosub banner
echo "main: n=$n"
gosub square
echo "main: got $result"
gosub banner
goto done_all

label banner
echo "======================"
ret

label square
result=$(( n * n ))
for k in 1 2; do
	[[ $k == 2 ]] && ret            # ret from inside a loop works
done
echo unreachable
ret

label done_all
echo "finished"
