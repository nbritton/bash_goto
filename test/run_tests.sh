#!/usr/bin/env bash
# run_tests.sh - QA driver: runs every test/t*.sh file and aggregates.
#
# usage: test/run_tests.sh [pattern]
#   With a pattern, only test files whose name contains it are run,
#   e.g. `test/run_tests.sh style` runs t02_style.sh alone.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1

pattern=${1-}
total_pass=0
total_fail=0
ran=0
bad_files=()

for tf in t[0-9]*.sh; do
	if [[ -n $pattern && $tf != *"$pattern"* ]]; then
		continue
	fi
	(( ++ran ))
	printf '=== %s ===\n' "$tf"
	out=$(bash "$tf" 2>&1)
	rc=$?
	printf '%s\n' "$out"
	summarized=0
	while IFS= read -r line; do
		if [[ $line =~ ^#\ pass=([0-9]+)\ fail=([0-9]+)$ ]]; then
			total_pass=$(( total_pass + BASH_REMATCH[1] ))
			total_fail=$(( total_fail + BASH_REMATCH[2] ))
			summarized=1
		fi
	done <<<"$out"
	if (( rc != 0 || summarized == 0 )); then
		bad_files+=("$tf")
	fi
done

printf -- '-----------------------------------------------\n'
if (( ran == 0 )); then
	printf 'no test files matched %s\n' "${pattern@Q}"
	exit 1
fi
printf 'TOTAL: %d passed, %d failed (%d files)\n' \
	"$total_pass" "$total_fail" "$ran"
if (( total_fail == 0 && ${#bad_files[@]} == 0 )); then
	printf 'RESULT: PASS\n'
	exit 0
fi
printf 'RESULT: FAIL'
(( ${#bad_files[@]} )) && printf ' [%s]' "${bad_files[*]}"
printf '\n'
exit 1
