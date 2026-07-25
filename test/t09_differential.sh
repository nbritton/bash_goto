#!/usr/bin/env bash
# shellcheck disable=SC2016
# (generated program text quotes $ expansions that must expand when the
#  generated program runs, not while it is being written)
# t09_differential.sh - randomized differential testing of both runtimes.
#
# Generates pseudo-random but always-valid goto programs and checks three
# independent answers against each other:
#
#   1. a reference interpreter that walks the generated control-flow
#      graph directly (__df_sim below) - it knows nothing about goto.sh
#   2. goto.sh       - the source-to-source compiler
#   3. goto_trap.sh  - the DEBUG-trap longjmp runtime
#
# A disagreement is a bug in whichever runtime differs from the model.
# Everything is seeded, so a failure reproduces exactly:
#
#     test/t09_differential.sh 47 1
#
# The generator uses its own LCG rather than $RANDOM because bash changed
# its RANDOM generator in 5.1: with $RANDOM the same seed would produce
# different programs on different bash versions, and a failure found in
# CI could not be reproduced locally.
#
# usage: t09_differential.sh [FIRST_SEED] [COUNT]
#        GOTO_FUZZ_N=500 test/run_tests.sh     # deeper nightly run

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
rootabs=$(cd "$root" && pwd) || exit 1

first_seed=${1:-1}
count=${2:-${GOTO_FUZZ_N:-40}}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/goto-t09.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

__df_state=0
__df_rand() {
	(( __df_state = (__df_state * 1103515245 + 12345) & 0x7FFFFFFF ))
	if (( $1 > 0 )); then
		(( rnd = (__df_state >> 13) % $1 ))
	else
		rnd=0
	fi
}

# --- program model --------------------------------------------------------
# nb        number of blocks
# wrap[i]   0 none | 1 for | 2 for+if | 3 for+while
# inner[i]  1 = the block's terminator sits inside that wrapper
# term[i]   fall | goto | comp (computed goto) | back (counted back edge)
# tgt[i]    target block
# trip[i]   how many times a back edge is taken
__df_gen() {
	local i rnd
	__df_state=$1
	__df_rand 5
	(( nb = rnd + 3 ))
	wrap=()
	inner=()
	term=()
	tgt=()
	trip=()
	for (( i = 0; i < nb; i++ )); do
		__df_rand 4
		wrap[i]=$rnd
		__df_rand 2
		inner[i]=$(( wrap[i] > 0 ? rnd : 0 ))
		__df_rand 10
		if (( i == nb - 1 || rnd < 3 )); then
			term[i]=fall
		elif (( rnd < 5 )); then
			term[i]=goto
		elif (( rnd < 7 )); then
			term[i]=comp
		else
			term[i]=back
		fi
		if [[ ${term[i]} == back ]]; then
			__df_rand $(( i + 1 ))
			tgt[i]=$rnd
			__df_rand 3
			trip[i]=$(( rnd + 1 ))
		else
			__df_rand $(( nb - i - 1 ))
			tgt[i]=$(( i + 1 + rnd ))
			trip[i]=0
		fi
	done
}

# --- emit the goto program ------------------------------------------------
# $1 = "compile" (run under goto.sh) or "trap" (source goto_trap.sh)
__df_emit() {
	local mode=$1 i pad body
	local -a out=()
	if [[ $mode == trap ]]; then
		out+=('#!/usr/bin/env bash')
		out+=("source \"$rootabs/goto_trap.sh\"")
	fi
	for (( i = 0; i < nb; i++ )); do
		out+=("label L$i")
		out+=("echo b$i")
		pad=''
		case ${wrap[i]} in
		1)
			out+=('for __w in 1 2; do')
			pad=$'\t'
			;;
		2)
			out+=('for __w in 1 2; do')
			out+=($'\tif (( __w == 1 )); then')
			pad=$'\t\t'
			;;
		3)
			out+=('for __w in 1 2; do')
			out+=($'\twhile :; do')
			pad=$'\t\t'
			;;
		esac
		(( wrap[i] )) && out+=("${pad}echo b$i.w\$__w")
		# inert decoys: these produce no output, but they put the
		# scanner's keywords in *data* position, where treating
		# them as commands desynchronizes the loop depth and
		# breaks the jumps below
		__df_rand 6
		case $rnd in
		0) out+=("${pad}for __k in done goto; do :; done") ;;
		1) out+=("${pad}case done in done) : ;; esac") ;;
		2) out+=("${pad}__d=\$(( 1 << 2 ))") ;;
		3) out+=("${pad}: \"label not-a-label\"") ;;
		esac
		body=''
		case ${term[i]} in
		goto) body="goto L${tgt[i]}" ;;
		comp)
			out+=("${pad}__t=L${tgt[i]}")
			body='goto "$__t"'
			;;
		back)
			body="(( __c$i < ${trip[i]} )) &&"
			body+=" { (( __c$i++ )); goto L${tgt[i]}; }"
			;;
		esac
		if (( inner[i] )) && [[ -n $body ]]; then
			out+=("${pad}${body}")
		fi
		case ${wrap[i]} in
		1) out+=('done') ;;
		2)
			out+=($'\tfi')
			out+=('done')
			;;
		3)
			out+=($'\t\tbreak')
			out+=($'\tdone')
			out+=('done')
			;;
		esac
		if (( ! inner[i] )) && [[ -n $body ]]; then
			out+=("$body")
		fi
	done
	printf '%s\n' "${out[@]}"
}

# --- reference interpreter ------------------------------------------------
# walks the same model directly, with no knowledge of either runtime
__df_sim() {
	local pc=0 steps=0 w reps jumped i
	local -a cnt=() lines=()
	for (( i = 0; i < nb; i++ )); do
		cnt[i]=0
	done
	while (( pc < nb )); do
		if (( ++steps > 4000 )); then
			printf 'SIM-RUNAWAY\n'
			return 1
		fi
		lines+=("b$pc")
		reps=0
		jumped=0
		(( wrap[pc] )) && reps=2
		for (( w = 1; w <= reps; w++ )); do
			# wrap 2 runs its body only on the first iteration
			(( wrap[pc] == 2 && w != 1 )) && continue
			lines+=("b$pc.w$w")
			if (( inner[pc] )); then
				case ${term[pc]} in
				goto|comp)
					pc=${tgt[pc]}
					jumped=1
					;;
				back)
					if (( cnt[pc] < trip[pc] )); then
						(( ++cnt[pc] ))
						pc=${tgt[pc]}
						jumped=1
					fi
					;;
				esac
				(( jumped )) && break
			fi
		done
		(( jumped )) && continue
		if (( ! inner[pc] )); then
			case ${term[pc]} in
			goto|comp)
				pc=${tgt[pc]}
				continue
				;;
			back)
				if (( cnt[pc] < trip[pc] )); then
					(( ++cnt[pc] ))
					pc=${tgt[pc]}
					continue
				fi
				;;
			esac
		fi
		(( ++pc ))
	done
	(( ${#lines[@]} )) && printf '%s\n' "${lines[@]}"
	return 0
}

declare -a wrap inner term tgt trip
declare -i nb=0
kept=0
for (( s = first_seed; s < first_seed + count; s++ )); do
	__df_gen "$s"
	if ! want=$(__df_sim); then
		t_not_ok "seed $s: the reference model ran away"
		continue
	fi

	__df_emit compile > "$tmp/p.sh"
	t_run bash "$root/goto.sh" "$tmp/p.sh"
	if [[ $t_out == "$want" ]] && (( t_status == 0 )); then
		t_ok "seed $s: goto.sh matches the reference"
	else
		cp "$tmp/p.sh" "$tmp/fail-compile-$s.sh"
		kept=1
		t_not_ok "seed $s: goto.sh matches the reference" \
		    "status $t_status
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$t_out") | head -10)
stderr: ${t_err:0:200}
rerun: test/t09_differential.sh $s 1"
	fi

	__df_emit trap > "$tmp/t.sh"
	t_run bash "$tmp/t.sh"
	if [[ $t_out == "$want" ]] && (( t_status == 0 )); then
		t_ok "seed $s: goto_trap.sh matches the reference"
	else
		cp "$tmp/t.sh" "$tmp/fail-trap-$s.sh"
		kept=1
		t_not_ok "seed $s: goto_trap.sh matches the reference" \
		    "status $t_status
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$t_out") | head -10)
stderr: ${t_err:0:200}
rerun: test/t09_differential.sh $s 1"
	fi
done

if (( kept )); then
	printf '# failing programs kept in %s\n' "$tmp" >&2
	trap - EXIT
fi

t_done
