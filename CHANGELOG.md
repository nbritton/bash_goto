# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-07-24

First public release: the compiler and trap runtimes brought into full
conformance with `bash-style-guide.md`, a 374-assertion test suite, a man
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
  masked a fall-off-the-end status to 0. (`exit N` and empty tail segments
  behave as before; the emitted code now tracks `__GOTO_RC`.)
- Clearer diagnostic for a `goto` inside `$( )`/`( )` or with an unquoted
  computed target: named for what it is, with a hint to quote computed
  targets, instead of a mangled `undefined label: lbl)` message.
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

### Known limitations

- An empty program (nothing after `source goto.sh`) is a syntax error
  rather than a no-op.
- Two heredocs on one line (`cmd <<A <<B`): the first line of B's body is
  briefly scanned as code, which can produce a spurious compile error
  (never silent misbehavior).
- `goto_trap.sh` indexes duplicate labels silently (last one wins);
  goto.sh rejects duplicates at compile time.
- `-E` output runs standalone only for programs that don't use
  `gosub`/`ret` (those reference `__gt_ret` from goto.sh).
- `$LINENO` and `BASH_SOURCE` inside a compiled program refer to the
  `eval`; see README limitations.

[1.0.0]: https://github.com/nbritton/bash_goto/releases/tag/v1.0.0
