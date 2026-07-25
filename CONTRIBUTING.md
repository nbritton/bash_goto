# Contributing

Thanks for looking under the hood. This project is small but exacting: it
is a compiler written in the language it compiles, and its correctness
story leans entirely on the test suite.

## Ground rules

Run the suite before and after your change:

```
bash test/run_tests.sh          # everything (exits nonzero on failure)
bash test/run_tests.sh unit     # just the files matching "unit"
```

All shell code follows `bash-style-guide.md` (tabs, 80 columns with tab=8,
`[[ ]]`, `(( ))`, parameter expansion over external commands, no `set -e`,
no `function` keyword, `local` everywhere). You do not have to memorize
it: `test/t02_style.sh` enforces it mechanically, including on the test
suite itself, and CI runs `make lint` (shellcheck at `-S style`, with
`-x -P SCRIPTDIR`) as its own job, with zero findings expected.

One line in each runtime is deliberately *not* in this style: the guard
that refuses a non-bash shell is written in POSIX shell, because `dash`
cannot parse `[[ ]]` and would die on the guard meant to protect it.
Those lines carry a `# POSIX` marker, which the style lint honours.

Two rules are absolute:

- **`eval` is allowed only in `goto.sh` and `goto_trap.sh`**, where it is
  the mechanism. The style lint fails anything else that uses it.
- **The runtimes fork no external commands.** Builtins and parameter
  expansion only; if you need `sed`, you probably want `${var//...}`.

## Architecture notes

`goto.sh` compiles in passes: pass 0 (acquisition + comment-label sugar),
pass 1 (parse via `eval` + `declare -f` readback), pass 2 (mask quoted
text and heredocs), pass 3+4 (scan the canonical token stream, validate,
emit the `case` trampoline). Each pass has focused unit tests in
`test/t03_unit.sh`; keep them growing with any change to the masker or
tokenizer — that is where the historical bugs lived.

The per-line compiler helpers (`__gt_err`, `__gt_classify`,
`__gt_rw_goto`, `__gt_rw_ret`, `__gt_chk_stray`) intentionally read and
write `__gt_compile_body`'s locals through bash dynamic scoping. It is the
documented convention here, not an accident.

## Golden files

`test/golden/` pins example outputs and the exact bytes of compiled
trampolines, including for `test/fixtures/orig_examples/` (style-variant
copies of the pre-1.0 examples — do not edit those fixtures).

If your change intentionally alters program output or emitted code:

1. run `bash test/gen_golden.sh`,
2. **review the golden diff line by line** — it is the compiled-code diff
   of your change,
3. commit the golden updates together with the change and a CHANGELOG
   entry.

If you did not intend to change emitted code and goldens moved, that is a
regression, not a golden update.

## Cutting a release

The version is authored in exactly one place, `__GT_VERSION` in `goto.sh`.
`test/t01_sanity.sh` fails if any copy drifts, so a half-finished bump
cannot ship:

1. bump `__GT_VERSION` in `goto.sh`
2. add the `## [X.Y.Z] - YYYY-MM-DD` section and the `[X.Y.Z]:` tag link
   to `CHANGELOG.md`
3. update the man page `.TH` line (version *and* date, which must equal
   the CHANGELOG date)
4. `make test` — the drift checks catch anything missed
5. `make fuzz` for a deeper randomized run
6. tag `vX.Y.Z`

## Behavior changes

User-visible behavior (messages, exit codes, emitted code shape) is locked
by `t04`–`t07`. Changing it deliberately means updating the locked test in
the same commit and noting it in `CHANGELOG.md`. Silent behavior drift is
the one thing this repo is built to prevent.
