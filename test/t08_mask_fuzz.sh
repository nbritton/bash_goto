#!/usr/bin/env bash
# shellcheck disable=SC2016
# (the fuzz fragments are program text: $ and ` must not expand here)
# t08_mask_fuzz.sh - property fuzzer for the pass-2 masker (__gt_mask).
#
# __gt_mask is the most bug-prone function in the compiler: every silent
# miscompile this project has shipped (a newline inside '...', `<<<`
# treated as a heredoc, `<<` inside (( )) treated as a heredoc) was a
# masking bug, and every one was found by a user rather than by a test.
# The masker has invariants that hold for *every* input, so they can be
# fuzzed instead of enumerated one case at a time:
#
#   I1  length is preserved             ${#masked} == ${#src}
#   I2  newlines stay at the same offsets, so the mask[] and src[] line
#       arrays in pass 3 stay in step
#   I3  every byte is either the filler X or the source byte itself -
#       the masker may blank, never substitute or reorder
#   I4  no keyword the scanner reacts to (label/goto/gosub/ret/do/done)
#       appears on a masked line unless it is live code on that line
#   I5  EQUIVALENCE: none of these fragments contains a live goto or
#       label, so compiling one must be a no-op - `bash prog` and
#       `goto.sh prog` must agree byte for byte on stdout and status.
#       This is the oracle that catches quoted text leaking into the
#       scanner and being rewritten.
#   I6  REACHABILITY: the same text with a real `goto`/`label` pair
#       appended must still compile and still jump.  I5 only catches a
#       masker that hides too little; I6 catches one that hides too much
#       and swallows the rest of the program (the 1.0.0 `<<` bug).
#
# Inputs are assembled by a seeded LCG (not $RANDOM: bash changed its
# generator in 5.1, which would make failures unreproducible across the
# very versions we want to compare) and filtered to those bash accepts,
# so only real programs are fuzzed.
#
# usage: t08_mask_fuzz.sh [FIRST_SEED] [COUNT]
#        GOTO_FUZZ_N=500 test/run_tests.sh     # deeper nightly run

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
cd "$here" || exit 1
source ./lib.sh
root=..
# shellcheck source=/dev/null
source "$root/goto.sh" --lib

first_seed=${1:-1}
count=${2:-${GOTO_FUZZ_N:-60}}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/goto-t08.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

__mf_state=0
__mf_rand() {
	(( __mf_state = (__mf_state * 1103515245 + 12345) & 0x7FFFFFFF ))
	if (( $1 > 0 )); then
		(( rnd = (__mf_state >> 13) % $1 ))
	else
		rnd=0
	fi
}

# fragments deliberately loaded with the words the scanner reacts to, so
# that a masking slip shows up as a keyword leaking into the mask
frags=(
'echo hi'
'echo "goto nowhere"'
"echo 'label sneaky'"
'echo "a\"b done"'
$'echo \'multi\nline done\''
'read -r x <<< "label herestring"'
$'cat <<EOF\ngoto boom\nlabel boom\nEOF'
$'cat <<-EOF\n\tdone\n\tgoto x\n\tEOF'
$'cat <<\'Q\'\nlabel quoted\nQ'
$'cat <<EOF\nEOFX is not the delimiter\ngoto trap\nEOF'
'x=$(echo "done")'
'x=`echo done`'
'(( m = 1 << 3 ))'
'(( n = 8 >> 1 ))'
'(( goto = done + 1 ))'
'x=$(( 1 << 2 ))'
'words=(goto label done)'
'echo @(goto|done)'
'echo a\ b'
$'echo one \\\necho two'
'echo "${x:-label d}"'
"echo \$'ansi\\'quote done'"
$'cat <<A; cat <<B\ngoto a\nA\nlabel b\nB'
'for i in 1; do echo done; done'
'echo "#: fakelabel"'
'echo "<<NOT_A_HEREDOC"'
'case done in done) echo m ;; esac'
$'cat <<\'END DOC\'\ngoto spaced\nEND DOC'
)

kw_re='(^|[^A-Za-z0-9_])(label|goto|gosub|ret|do|done)([^A-Za-z0-9_]|$)'

for (( s = first_seed; s < first_seed + count; s++ )); do
	__mf_state=$s
	__mf_rand 4
	nf=$(( rnd + 1 ))
	src=''
	for (( f = 0; f < nf; f++ )); do
		__mf_rand ${#frags[@]}
		src+=${frags[rnd]}$'\n'
	done
	src=${src%$'\n'}
	# only fuzz inputs bash itself accepts as a program
	bash -O extglob -n <<<"$src" 2> /dev/null || continue

	masked=$(__gt_mask "$src")

	# I1 length
	if (( ${#masked} == ${#src} )); then
		t_ok "seed $s: mask preserves length"
	else
		t_not_ok "seed $s: mask preserves length" \
		    "got ${#masked}, want ${#src}
src: ${src@Q}"
	fi

	# I2 newline offsets
	npos_ok=1
	bad_at=-1
	for (( i = 0; i < ${#src}; i++ )); do
		a=0
		b=0
		[[ ${src:i:1} == $'\n' ]] && a=1
		[[ ${masked:i:1} == $'\n' ]] && b=1
		if (( a != b )); then
			npos_ok=0
			bad_at=$i
			break
		fi
	done
	if (( npos_ok )); then
		t_ok "seed $s: newlines sit at the same offsets"
	else
		t_not_ok "seed $s: newlines sit at the same offsets" \
		    "first divergence at offset $bad_at
src: ${src@Q}"
	fi

	# I3 blank-or-copy
	sub_ok=1
	bad_at=-1
	for (( i = 0; i < ${#src}; i++ )); do
		[[ ${masked:i:1} == X || ${masked:i:1} == "${src:i:1}" ]] &&
		    continue
		sub_ok=0
		bad_at=$i
		break
	done
	if (( sub_ok )); then
		t_ok "seed $s: mask only blanks bytes, never substitutes"
	else
		t_not_ok "seed $s: mask only blanks bytes" \
		    "offset $bad_at
src: ${src@Q}"
	fi

	# I4 no keyword leaks out of a masked region
	leaked=''
	while IFS= read -r ml && IFS= read -r sl <&3; do
		[[ $ml =~ $kw_re ]] || continue
		[[ $sl =~ $kw_re ]] && continue
		leaked+="mask: ${ml@Q}"$'\n'
		leaked+="src:  ${sl@Q}"$'\n'
	done < <(printf '%s\n' "$masked") 3< <(printf '%s\n' "$src")
	if [[ -z $leaked ]]; then
		t_ok "seed $s: no keyword leaks into the mask"
	else
		t_not_ok "seed $s: no keyword leaks into the mask" "$leaked"
	fi

	# I5 equivalence: compiling a goto-free program changes nothing
	printf '%s\n' "$src" > "$tmp/p.sh"
	t_run bash -O extglob "$tmp/p.sh"
	plain_out=$t_out
	plain_rc=$t_status
	t_run bash -O extglob "$root/goto.sh" "$tmp/p.sh"
	if [[ $t_out == "$plain_out" ]] && (( t_status == plain_rc )); then
		t_ok "seed $s: compiling a goto-free program is a no-op"
	else
		t_not_ok "seed $s: compiling a goto-free program is a no-op" \
		    "status: plain $plain_rc, compiled $t_status
stderr: ${t_err:0:200}
src: ${src@Q}"
	fi

	# I6 reachability: the same text plus a real jump must still jump
	printf '%s\n' "$src" > "$tmp/j.sh"
	printf 'goto __fz_end\necho FUZZ-NOT-SKIPPED\n' >> "$tmp/j.sh"
	printf 'label __fz_end\necho fz-ok\n' >> "$tmp/j.sh"
	t_run bash -O extglob "$root/goto.sh" "$tmp/j.sh"
	want=$plain_out$'\n'fz-ok
	[[ -z $plain_out ]] && want=fz-ok
	if [[ $t_out == "$want" ]] && (( t_status == plain_rc )); then
		t_ok "seed $s: an appended goto still compiles and jumps"
	else
		t_not_ok "seed $s: an appended goto still compiles and jumps" \
		    "status: want $plain_rc, got $t_status
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$t_out") | head -8)
stderr: ${t_err:0:200}
src: ${src@Q}"
	fi
done

t_done
