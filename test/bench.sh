#!/usr/bin/env bash
# bench.sh - stable, comparable numbers for before/after comparisons.
#
# Deliberately NOT named t*.sh, so run_tests.sh does not pick it up: this
# is a tool a human runs, not an assertion.  Timings use EPOCHREALTIME so
# the measurement loop forks nothing, and each case reports the best of
# three runs, which makes run-to-run jitter about 3-5%.
#
#     test/bench.sh > before.txt
#     ...change something...
#     test/bench.sh > after.txt
#     diff -u before.txt after.txt
#
# usage: bench.sh [CASE_SUBSTRING]

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
root=..
rootabs=$(cd "$root" && pwd) || exit 1
filter=${1-}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/goto-bench.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# best-of-3 wall time in milliseconds for a command
bench_ms() {
	local best=0 t0 t1 ms i
	for i in 1 2 3; do
		t0=${EPOCHREALTIME/./}
		"$@" > /dev/null 2>&1
		t1=${EPOCHREALTIME/./}
		ms=$(( (t1 - t0) / 1000 ))
		(( best == 0 || ms < best )) && best=$ms
	done
	printf '%s' "$best"
}

# report CASE MS UNIT_COUNT UNIT_NAME
report() {
	local name=$1 ms=$2 n=$3 unit=$4 per=0
	if (( n > 0 && ms > 0 )); then
		(( per = ms * 1000 / n ))
	fi
	printf '%-38s %6s ms  %6s us/%s\n' "$name" "$ms" "$per" "$unit"
}

want() {
	[[ -z $filter || $1 == *"$filter"* ]]
}

printf '# goto.sh benchmark (%s, best of 3)\n' "$(bash --version | head -1)"

# --- compile time scales with label count ---------------------------------
for n in 50 100 200 400; do
	want "compile $n labels" || continue
	: > "$tmp/lbl.sh"
	for (( i = 0; i < n; i++ )); do
		printf 'label L%d\necho %d\n' "$i" "$i" >> "$tmp/lbl.sh"
	done
	ms=$(bench_ms bash "$root/goto.sh" -E "$tmp/lbl.sh")
	report "compile $n labels" "$ms" "$n" label
done

# --- compile time scales with plain program size --------------------------
for n in 200 800; do
	want "compile $n plain lines" || continue
	: > "$tmp/plain.sh"
	for (( i = 0; i < n; i++ )); do
		printf 'x%d=%d\n' "$i" "$i" >> "$tmp/plain.sh"
	done
	ms=$(bench_ms bash "$root/goto.sh" -E "$tmp/plain.sh")
	report "compile $n plain lines" "$ms" "$n" line
done

# --- jump throughput, compiled runtime ------------------------------------
for n in 20000 100000; do
	want "goto.sh $n jumps" || continue
	printf 'i=0\nlabel top\n(( i++ ))\n(( i < %d )) && goto top\n' "$n" \
	    > "$tmp/j.sh"
	ms=$(bench_ms bash "$root/goto.sh" "$tmp/j.sh")
	report "goto.sh $n jumps" "$ms" "$n" jump
done

# --- jump throughput, trap runtime ----------------------------------------
for n in 500 2000; do
	want "goto_trap.sh $n jumps" || continue
	printf '#!/usr/bin/env bash\nsource "%s/goto_trap.sh"\n' "$rootabs" \
	    > "$tmp/tj.sh"
	printf 'i=0\nlabel top\n(( i++ ))\n(( i < %d )) && goto top\n' "$n" \
	    >> "$tmp/tj.sh"
	ms=$(bench_ms bash "$tmp/tj.sh")
	report "goto_trap.sh $n jumps" "$ms" "$n" jump
done

# --- the masker, the compiler's hot inner loop ----------------------------
if want '__gt_mask'; then
	: > "$tmp/q.sh"
	for (( i = 0; i < 300; i++ )); do
		printf 'echo "quoted %d" '"'"'single %d'"'"'\n' "$i" "$i" \
		    >> "$tmp/q.sh"
	done
	ms=$(bench_ms bash "$root/goto.sh" -E "$tmp/q.sh")
	report '__gt_mask 300 quoted lines' "$ms" 300 line
fi
