# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-07-25

A correctness release. A full audit of the 1.0.0 code found several ways a
program could be **silently miscompiled** — the worst failure mode this tool
can have, since the program runs and produces wrong output with no
diagnostic. Every one is fixed, and every one is now locked by a test.

The test suite grew from 383 to 888 assertions, including two randomized
harnesses that reproduce the whole class of bug rather than the specific
instances: both fail against 1.0.0 and pass here.

### Fixed — silent miscompiles

- **`<<` inside `(( ))` was read as a heredoc.** `(( bit = 1 << i ))` opened
  a heredoc whose delimiter never arrived, so the masker blanked *the rest of
  the program*: labels disappeared, `goto`s were left uncompiled, and the
  program ran to completion with the wrong control flow and exit status 0.
- **Shell keywords in data position were treated as commands.** In
  `for w in done x; ...` or a `case` pattern such as `ret)`, the scanner saw
  `done`/`ret`/`goto` as commands. Depending on the word this rejected valid
  programs, miscounted loop depth (emitting `continue N` with the wrong N, so
  a jump escaped the wrong loop), or generated code that would not parse.
- **A caller's `IFS` disabled the entire token pass.** With `IFS=:` set before
  `source goto.sh`, no `goto` was rewritten, no loop depth was tracked, and no
  stray `break` was diagnosed — the program simply ran uncompiled.
- **A caller's `nocasematch` corrupted the scanner**, turning a user command
  named `Label` or `Do` into compiler syntax.
- **Pass 0 edited heredoc bodies.** A `# label x` line or a `source …goto.sh`
  line *inside a heredoc* was rewritten or deleted. The `source` pattern was
  also unanchored, so `source ./lib_nogoto.sh` was silently dropped.
- **`goto` inside backticks** was never compiled and never diagnosed; it now
  fails at compile time.

### Fixed — silent failures and misleading errors

- **`$?` is now transparent across a label boundary and a `goto`.** Previously
  the trampoline's program-counter assignment reset it to 0, which broke the
  `cmd; goto err; … label err; echo $?` idiom — error handling being the main
  reason to want `goto` at all. The restore is skipped under `errexit`, where
  re-raising a status would exit a program plain bash would have kept running.
- **`source goto.sh` from a script fed on stdin** (`cat prog.sh | bash`) has no
  file to read the program from, so nothing was ever compiled and every `goto`
  silently fell through to the no-op stub. It is now a clear error.
- **`source goto.sh` inside a function** compiled from the wrong offset and
  looped forever. Now diagnosed.
- **`goto` inside a function body** compiled to a `continue` that bash rejected
  at run time, after which execution simply carried on. Now a compile error
  naming `goto_trap.sh` as the alternative.
- **`goto` inside `$( )` or `( )`** produced a syntax error or a mangled
  "undefined label" message; it is now diagnosed as crossing a subshell.
- **A conditional `gosub`** (`true && gosub x`) was silently left uncompiled.
- **A label in the reserved `__gt_`/`__GOTO_` namespace** could collide with a
  generated segment name and hang the dispatch; now rejected.
- Empty and comment-only programs compiled to a bash syntax error about a
  closing brace; they now compile to an empty trampoline.
- `goto.sh -E` did not check its argument, and a directory passed the
  readability test; both now produce the same clear message as other paths.
- The subshell guard signalled a recorded pid without checking it was still
  alive, so after pid reuse the `SIGTERM` could land on an unrelated process.

### Fixed — goto_trap.sh

- **`set -e` made every `goto` fatal.** The DEBUG-trap `return 2` that performs
  the longjmp looked like a failing command to `errexit`, killing the shell
  with a bash-internal `pop_var_context` message. Since `set -euo pipefail` is
  the standard preamble, this made the runtime unusable for a large share of
  real programs. `errexit` is now suspended for the unwind and restored
  immediately after the jump.
- **The program's exit status was masked to 0** — the same defect the compiler
  fixed in 1.0.0. A program ending in a failing command now exits nonzero.
- **Command-line arguments never reached the program**: `$1` was the internal
  line number, and `$#` was always 1. `"$@"` now passes through.
- **A `label` line inside a heredoc body was indexed as a jump target**, which
  sent the trampoline into the middle of the heredoc and hung the program in an
  endless loop. Heredoc bodies are skipped when indexing.
- **Losing the DEBUG trap degraded silently** into "run to the end, then jump",
  executing the code the jump was meant to skip. It is now a fatal error.
- `label NAME;` with a trailing semicolon is accepted, matching goto.sh.

### Added

- `test/t08_mask_fuzz.sh` — property fuzzer for the masker: length, newline
  offsets, blank-or-copy, keyword containment, and two end-to-end oracles
  (compiling a jump-free program is a no-op; appending a real jump still
  jumps). Seeded, so failures reproduce exactly.
- `test/t09_differential.sh` — randomized differential testing: generated
  control-flow graphs are run through an independent reference interpreter,
  the compiler, and the trap runtime, and all three must agree.
- `test/bench.sh` — benchmark harness producing stable, diffable numbers.
- A version single-source-of-truth check: `__GT_VERSION`, the man page `.TH`
  line, and the CHANGELOG heading, date, and tag link must agree, so a release
  bump cannot half-land.
- Emitted trampolines are now **self-contained**: `-E` output runs on its own,
  including programs using `gosub`/`ret` or the subshell guard.
- `SECURITY.md`, `.gitattributes`, and a provenance note for the vendored
  style guide; CI gained a bash 5.0–5.3 matrix, a `make lint` job, and a
  packaging smoke test.

### Changed

- Both runtimes now refuse a non-bash shell using a POSIX-parseable guard, so
  `sh`/`dash` print the message instead of dying on `[[`.
- The style lint checks each line through the compiler's own masker, so a
  pattern inside a string literal is no longer a false positive.
- `test/run_tests.sh` counts only the last summary line per file, so output
  from a program under test cannot inflate the total.

### Performance

- `goto_trap.sh` jumps: unchanged at roughly 250 µs each (the errexit and
  DEBUG-liveness bookkeeping is not measurable against the cost of the
  re-eval).
- `goto.sh` jumps: 6 µs → 8 µs, the cost of making `$?` transparent. The
  common path (status 0) is one arithmetic test with no function call.
  Compilation is 5–15% slower for the added scanning; both runtimes still fork
  no external commands.

### Known limitations

- Under `set -e`, an errexit-triggered exit inside a `goto_trap.sh` program
  prints two `pop_var_context` lines from bash itself. The exit status is
  correct; the noise comes from bash unwinding an `eval` inside a function
  with `functrace` on and cannot be suppressed from the script.
- `goto_trap.sh` implements `label`/`goto` only — not `gosub`/`ret` — and its
  labels must be top-level, since the trampoline re-evaluates from the label
  to end of file.
- Two heredocs on one line (`cmd <<A <<B`) can still produce a spurious
  compile error; it is never silent.
- `declare` at the top level of a `goto_trap.sh` program creates a
  function-local variable (the program body is evaluated inside a function);
  use `declare -g`.

## [1.0.0] - 2026-07-24

First public release: the compiler and trap runtimes brought into full
conformance with `bash-style-guide.md`, a 383-assertion test suite, a man
page, and packaging.

### Added

- QA test suite under `test/` (`test/run_tests.sh`; CI-ready, exits nonzero
  on failure): sanity, a mechanical style-guide lint that the suite itself
  must pass, unit tests for every compiler pass, all diagnostics, all
  invocation modes, and byte-exact emission goldens.
- `goto.sh -V` / `--version`.
- A bash >= 5 version guard in both runtimes: old bash now gets a clear
  one-line error instead of a confusing mid-script failure.
- `goto_trap.sh` subshell/pipeline guard: a `goto` executed inside `$( )`,
  `( )`, or a pipeline is now a loud fatal error (exit 70, matching
  goto.sh's guard) instead of being **silently lost**. `GOTO_STRICT=0`
  disables it, as with goto.sh.
- Compile-time validation of `gosub` targets (previously only caught at run
  time as a missing-label error).
- Man page (`man/goto.sh.1`, with `goto_trap.sh.1` as an alias), `Makefile`
  (`test`, `lint`, `install`, `uninstall`), MIT `LICENSE`, GitHub Actions
  CI (Linux + macOS), `CONTRIBUTING.md`.

### Changed

- Full conformance with `bash-style-guide.md`: tabs, 80 columns, `[[ ]]`,
  `(( ))` arithmetic, parameter expansion over external commands.
- **Zero external commands in both runtimes.** Previously goto.sh forked
  `sed`, `tail`, `grep`, `cut`, `sort`, and `rm`, and goto_trap.sh forked
  `grep` plus one `tail` per jump. Jump-heavy goto_trap programs run about
  10x faster; goto.sh no longer creates any temp file (the predictable
  `/tmp/.gt_syntax.$$` is gone).
- **Exit status now propagates.** A program whose last command fails exits
  with that status, as it would in plain bash; previously the trampoline
  masked a fall-off-the-end status to 0.
- Clearer diagnostic for a `goto` inside `$( )`/`( )` or with an unquoted
  computed target.
- `goto.sh -h` prints the header comment dynamically (was a hard-coded
  `sed` line range that had already drifted from the real header).

### Fixed

- Masker: a newline inside a multi-line single-quoted string was dropped,
  desynchronizing the mask/source line arrays — later rewrites landed on
  the wrong lines and produced a broken compiled program.
- Masker: `<<<` herestrings were misread as heredoc openers, so everything
  after one was masked away — labels silently ignored and `goto`s left
  uncompiled, with no diagnostic.
- Validation: a program merely *printing* the text `__GOTO_PC=...` inside a
  string literal was rejected as a goto to an undefined label.

[1.0.1]: https://github.com/nbritton/bash_goto/releases/tag/v1.0.1
[1.0.0]: https://github.com/nbritton/bash_goto/releases/tag/v1.0.0
