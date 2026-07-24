#!/usr/bin/env bash
# The two cases the fd-255 trick handles awkwardly: a forward jump, and a
# backward jump that does NOT re-exec the script or lose shell state.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../goto.sh"

echo line 1
goto skip
echo "you should never see this"
label skip
echo line 3

echo "--- backwards: a loop built out of nothing but goto ---"
i=0
state="untouched by any re-exec"
label top
echo "iteration $i  ($state)"
: $(( i++ ))
(( i < 3 )) && goto top
echo "done, and \$state survived: $state"
