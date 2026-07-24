#!/usr/bin/env bash
# gen_golden.sh - regenerate golden files from the CURRENT tree.
#
# Run this only when an output or emission change is intended, and
# review the diff before keeping it.

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
root=..

mkdir -p golden
for ex in "$root"/examples/0*.sh; do
	name=${ex##*/}
	num=${name%%_*}
	bash "$ex" > "golden/$num.out"
	printf 'wrote golden/%s.out\n' "$num"
done
for n in 01 02 03 04 05; do
	ex=("$root/examples/${n}_"*.sh)
	bash "$root/goto.sh" -E "${ex[0]}" > "golden/emit_$n.txt"
	printf 'wrote golden/emit_%s.txt\n' "$n"
done
for n in 01 02 03 04 05; do
	fx=("fixtures/orig_examples/${n}_"*.sh)
	bash "$root/goto.sh" -E "${fx[0]}" > "golden/emit_fixture_$n.txt"
	printf 'wrote golden/emit_fixture_%s.txt\n' "$n"
done
