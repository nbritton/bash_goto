# goto.sh — real forward and backward GOTO for bash 5.x

[![ci](https://github.com/nbritton/bash_goto/actions/workflows/ci.yml/badge.svg)](https://github.com/nbritton/bash_goto/actions/workflows/ci.yml)

Two independent implementations of `label` / `goto` for bash, both of which keep
full shell state across a backward jump (no re-exec, no lost variables, no lost
file descriptors).

| | `goto.sh` | `goto_trap.sh` |
|---|---|---|
| mechanism | compile to a `case` dispatch trampoline | DEBUG-trap longjmp + tail-eval |
| front end | bash's own parser, via `declare -f` | label line numbers only |
| jump out of nested loops | yes (`continue N`, N computed at compile time) | yes |
| jump out of a called **function** | no (C semantics: goto is function-local) | **yes** |
| `gosub` / `ret` | yes | no |
| compile-time diagnostics | yes | no |
| speed | normal bash speed | slow (trap fires before every command) |
| footprint | none at runtime | owns the DEBUG trap and `extdebug` |

## Requirements and installation

GNU bash **5 or newer** — both runtimes check and refuse older bash with a
clear error. CI runs the full suite against bash 5.0, 5.1, 5.2 and 5.3 on
Linux and against Homebrew bash on macOS. Neither runtime forks a single
external command, so there are no other dependencies.

Nothing to build:

```
git clone https://github.com/nbritton/bash_goto
cd bash_goto
make test            # run the QA suite
sudo make install    # scripts to /usr/local/bin, man pages installed
make uninstall       # remove them; PREFIX=... relocates both targets
```

With the scripts on `PATH`, a program's first line becomes
`source "$(command -v goto.sh)"`. See `man goto.sh` for the reference
manual.

---

## Quick start

```bash
#!/usr/bin/env bash
source ./goto.sh          # takes over the rest of this file

echo line 1
goto skip
echo "you will never see this"
label skip
echo line 3
```

```
$ ./prog.sh
line 1
line 3
```

Backward jumps are the same word, and the shell keeps everything:

```bash
i=0
label top
echo "iteration $i"
(( i++ ))
(( i < 3 )) && goto top
```

---

## Syntax

| word | meaning |
|---|---|
| `label NAME` | jump target. Must sit at the top level of the program. |
| `# label NAME` or `#: NAME` | same thing as a comment (compatible with the ysap style). |
| `goto NAME` | jump. Forward, backward, or into a variable: `goto "$dest"`. |
| `gosub NAME` … `ret` | call/return with a real return stack (`goto.sh` only). `gosub` must be top-level; `ret` can be anywhere. |

`label`, `goto`, `gosub` and `ret` are also defined as ordinary functions, so an
*uncompiled* run of the program still parses as valid bash — `label` is a no-op
and `goto` reports that the file was never compiled.

## Invocation

```bash
source goto.sh                       # compile + run the remainder of the caller
source goto.sh --lib                 # just define goto_compile / goto_run
goto.sh prog.sh arg1 arg2            # run prog.sh, "$@" preserved
goto.sh -E prog.sh                   # dump the compiled trampoline, don't run
goto.sh -V                           # print name and version
#!/path/to/goto.sh                   # as a shebang interpreter
eval "$(goto_compile <<'EOF' ... EOF)"   # heredoc form; runs in the current shell
```

| variable | effect |
|---|---|
| `GOTO_EMIT=1` | print the compiled program to stderr before running it |
| `GOTO_STRICT=0` | drop the runtime subshell guard, in both runtimes (see below) |

The program's exit status is propagated faithfully — an explicit `exit`,
or the status of the last command before falling off the end, exactly as
in plain bash.

---

## How the compiler works

Four passes.

**Pass 0 — acquisition.** `source goto.sh` finds the caller with
`${BASH_SOURCE[1]}` and the `source` line with `${BASH_LINENO[0]}`, and takes
everything after it. Comment-style labels are rewritten into real `label`
commands here.

**Pass 1 — parse, using bash itself.** The program is `eval`'d as a function
body and read back with `declare -f`. That is the whole front end: bash
pretty-prints its own parse tree in canonical form — one command per line,
canonical quoting, four spaces of indent per nesting level, aliases already
expanded. "Write a bash parser" becomes "scan a canonical token stream."

A useful side effect: aliases defined before the `source` line are expanded at
parse time, so they act as C-preprocessor macros over `goto`:

```bash
alias REPEAT_WHILE_UNDER='(( count < 3 )) && goto'
...
REPEAT_WHILE_UNDER loop
```

**Pass 2 — masking.** Quoted regions, arithmetic, array-assignment and extglob
data, and heredoc bodies are replaced with `X`, preserving offsets and
newlines. Heredoc delimiters are queued in source order, including multiple
redirections on one command and quoted delimiters containing spaces. This is
why `echo done`, an array element named `goto`, and a heredoc containing
`goto nowhere` are all correctly inert.

**Pass 3 — scan and validate.** A small tokenizer walks each masked line
tracking command position, because `do` and `done` are only keywords as the
first word of a command (`echo do` must not count). It also keeps `[[ ... ]]`
expression words in data position, maintains loop depth including conditions
before their `do`, rewrites each `goto`, and rejects the things that cannot
work.

**Pass 4 — emit.** Segments between labels become `case` branches:

```bash
declare -g __GOTO_SHELL=$BASHPID __GOTO_PC=__gt_entry
declare -ga __GOTO_STACK=()
declare -g __GOTO_RC=0
__gt_rc() { return "${1:-0}"; }          # restores $? without a fork
while :; do
  case $__GOTO_PC in
    (__gt_entry)
      __GOTO_PC=skip                     # fall through to the next segment
      (( __GOTO_RC == 0 )) || { [[ $- == *e* ]] || __gt_rc "$__GOTO_RC"; }
      echo line 1;
      { __GOTO_RC=$?; __GOTO_PC=skip; ...; continue 1; }
      echo "you will never see this";
      __GOTO_RC=$?                       # so falling off the end keeps $?
      ;;
    (skip)
      __GOTO_PC=__gt_END
      (( __GOTO_RC == 0 )) || { [[ $- == *e* ]] || __gt_rc "$__GOTO_RC"; }
      echo line 3
      __GOTO_RC=$?
      ;;
    (__gt_END) break ;;
    (*) printf "goto: no such label: %s\n" "$__GOTO_PC" >&2; exit 2 ;;
  esac
done
(exit "$__GOTO_RC")
```

(The header comment and the subshell guard are elided above; run
`goto.sh -E prog.sh` for the real thing. The `__GOTO_RC` bookkeeping is what
makes `$?` transparent across a label boundary and across a `goto` — the
status a segment ends with is the status the next one starts with, exactly
as in the same program with the labels deleted.)

Each branch sets the pc to the *next* segment before running, so falling off the
end of a segment falls through to the following label, exactly like C. Each
code segment records its last command's status, and the final line replays it,
so the compiled program's exit status matches what plain bash would give.

`goto X` compiles to `{ __GOTO_RC=$?; __GOTO_PC=X; <guard> continue N; }`,
where **N is the lexical loop-nesting depth plus one**, computed at compile
time (the guard is the subshell check, dropped by `GOTO_STRICT=0`). That is
what makes a jump out of two nested `for` loops work: it emits `continue 3`. Wrapping the
jump in `{ ; }` rather than emitting bare statements keeps it correct inside
`&&`/`||` lists.

Because the pc is a string and dispatch is a `case`, computed gotos are free —
`goto "$state"` needs no extra machinery.

`gosub` is handled by generating an anonymous return label, splitting the
segment at the call site, and pushing that label onto `__GOTO_STACK`.

---

## Diagnostics

Compile time:

```
goto.sh: error: goto to undefined label: nowhere
goto.sh: error: gosub to undefined label: banner
goto.sh: error: duplicate label a
goto.sh: error: goto cannot cross a subshell or command substitution
                (the jump would run in a child process)
goto.sh: error: goto inside a function body cannot leave it
                (use goto_trap.sh if you need to jump out of a call)
goto.sh: error: `goto` inside a `...` command substitution can never jump
goto.sh: error: `goto` without a target
goto.sh: error: `goto` takes exactly one target
goto.sh: error: `ret` takes no arguments
goto.sh: error: `goto` cannot have an assignment or redirection prefix
goto.sh: error: label must be a plain `label NAME` at the top level
goto.sh: error: label start is not at the top level of the program
                (bash cannot jump into a loop, function or block)
goto.sh: error: goto target lbl) is not a valid label name
                (quote computed targets: goto "$var"; a goto
                cannot cross $( ), ( ) or a pipeline)
goto.sh: error: `break` outside any loop would hijack the trampoline (line: break)
goto.sh: syntax error in program: ...
```

Run time — a `goto` that crossed a subshell or pipeline boundary is caught by
comparing `BASHPID` against the pid recorded when the trampoline started:

```
goto: fatal: `goto a` executed in a subshell or pipeline (pid 26908 != 26891)
```

Obvious subshell and command-substitution cases are rejected at compile time.
The run-time `BASHPID` check remains the exact backstop for pipelines and other
child-process contexts.

## Limitations

* **Labels must be at the top level of the program.** You cannot jump into the
  middle of a loop, a function, or a `{ ; }` block — the `case` branch would not
  be syntactically complete. C forbids most of this too.
* **`goto` is function-local**, as in C — and a `goto` inside a function body
  is rejected at compile time. Use `goto_trap.sh` if you need to jump out of
  a called function.
* **No `goto` across a subshell or pipeline.** Trapped at run time.
* **Bare `break`/`continue` outside your own loops is rejected**; it would
  hijack the trampoline.
* `$LINENO` and `BASH_SOURCE` inside the compiled program refer to the `eval`,
  not the original file. `GOTO_EMIT=1` gives you the text that is actually
  running.
* Comments are gone after pass 1 (`declare -f` discards them). That is why
  `# label foo` is rewritten in pass 0, before parsing.
* Reading the program from stdin (`goto.sh < prog.sh`) consumes stdin, so the
  program cannot then read from it. Use a filename or the heredoc form.
* Names starting with `__gt_`, `__GOTO_` (compiled runtime) and `__GT_` (trap
  runtime) are reserved — programs should not define or assign them.
* `goto_trap.sh` implements `label`/`goto` only — not `gosub`/`ret` — and its
  labels must be top-level too: the trampoline re-evaluates the program text
  from the label to end of file, so a label inside a loop or block is a
  syntax error at jump time.
* In a `goto_trap.sh` program, `declare` at the top level creates a
  *function-local* variable, because the program body is evaluated inside the
  trampoline function. Use `declare -g` (plain `x=1` assignments are fine).
* Under `set -e`, an errexit-triggered exit inside a `goto_trap.sh` program
  prints two `pop_var_context` lines from bash itself. The exit status is
  correct; the noise is bash unwinding an `eval` inside a function and cannot
  be suppressed from the script.
* `source goto.sh` needs a real file to read the rest of the program from, so
  `cat prog.sh | bash` cannot work — it is diagnosed, not silently ignored.
* The shebang-interpreter form (`#!/path/to/goto.sh`) needs a kernel that
  accepts scripts as shebang interpreters: Linux does, macOS does not.

---

## The other runtime: `goto_trap.sh`

No compiler pass at all. Two bash facts do the work:

**Tail-eval trampoline.** "Jump to label L" is just "evaluate the program text
from L's line to EOF." A `while` loop around that `eval` is the trampoline, and
each jump is a tail call into a fresh `eval`, so the eval stack never grows no
matter how many jumps happen. Only label *line numbers* are needed — no
parsing, no segmentation, no nesting analysis.

**DEBUG-trap longjmp.** From the bash manual: with `shopt -s extdebug`, if the
DEBUG trap returns 2 while the shell is in a subroutine, the shell *simulates a
return*. The trap fires before every command, so a pending jump unwinds one
frame per command until it reaches the trampoline. That is a genuine longjmp:
it escapes nested loops, `case`, `if`, `{ ; }` — and user functions, including
recursive ones:

```bash
helper() {
  local d=$1
  (( d > 2 )) && goto after_helper     # unwinds 3 frames and the eval
  helper $(( d + 1 ))
}
helper 1
label after_helper
```

The guard is a single test:

```bash
__gt_dbg() {
	[[ -n $__GT_PC && ${FUNCNAME[1]} != __gt_run ]] && return 2
	return 0
}
```

`__gt_run` excludes itself so the cascade stops at the trampoline instead of
unwinding it too.

The cost is real: a function call before every command in the program.
`goto.sh` is the one to use; this one is the proof that the compiler is
optional.

The same subshell guard applies here: a `goto` executed inside `$( )`,
`( )` or a pipeline is a loud fatal error rather than a silently lost
jump, and `GOTO_STRICT=0` disables it.

---

## Why not the `read -u 255` trick

Bash reads a script through fd 255 and keeps that descriptor's offset in sync at
command boundaries, so consuming lines from it moves the parser forward. That
gives a forward `goto` in three lines and nothing else:

* backward jumps need `exec`-ing the script again, so every unexported variable,
  function, array, and open descriptor is lost, and the "jump" costs a process;
* the jump target must be found by scanning at run time, every time;
* it interacts badly with anything else reading the script;
* there is no way to diagnose a bad label before the program is already running.

The trampoline keeps the process, keeps the state, and turns "does this label
exist" into a compile-time question.

---

## Files

```
goto.sh                                  the compiler + trampoline runtime
goto_trap.sh                             the DEBUG-trap longjmp runtime
examples/                                six runnable demonstrations
test/run_tests.sh                        QA driver: runs the whole suite
test/lib.sh                              assertion helpers
test/t0*.sh                              sanity, style lint, unit, diagnostics,
                                         functional, regression, trap runtime,
                                         masker fuzzer, differential fuzzer
test/bench.sh                            benchmarks (not part of the suite)
test/gen_golden.sh                       regenerate the golden files
test/golden/                             pinned outputs and emitted code
test/fixtures/                           frozen inputs for regression tests
.github/workflows/ci.yml                 bash 5.0-5.3, macOS, lint, packaging
man/goto.sh.1                            the manual page
Makefile                                 test / lint / install / uninstall
bash-style-guide.md                      vendored: Dave Eddy's guide (MIT),
                                         the style rules t02 enforces
CHANGELOG.md, CONTRIBUTING.md, LICENSE   release history, dev guide, MIT
SECURITY.md                              what "it evals your program" implies
```

Run them with `bash examples/01_forward_and_backward.sh`, and add
`GOTO_EMIT=1` to see the generated trampoline for any of them.

The shebang-interpreter form (`#!/path/to/goto.sh`) needs a kernel that
accepts a script as an interpreter: Linux does, macOS does not, and no kernel
accepts an interpreter path containing a space.

## Testing

```
test/run_tests.sh              # the whole suite (exits nonzero on failure)
test/run_tests.sh style        # just the files matching "style"
```

The suite covers a mechanical style-guide lint (which the test files
themselves must pass), unit tests for each compiler pass, every diagnostic
and invocation mode, and byte-exact goldens for the emitted trampolines —
including emissions of style-variant fixture sources, so code generation
cannot drift unnoticed.

Two files are randomized rather than enumerated, because every silent
miscompile this project has shipped was a masking bug of a kind that is
easier to fuzz than to foresee:

```
test/t08_mask_fuzz.sh      properties of the quote/heredoc masker
test/t09_differential.sh   generated control flow, checked against an
                           independent reference interpreter
```

Both are seeded, so a failure reproduces exactly (`test/t09_differential.sh
47 1` re-runs seed 47 alone). `make fuzz` runs them deeply.

`make bench` prints comparable timing numbers, `CHANGELOG.md` carries the
release history and known limitations, and `CONTRIBUTING.md` explains the
golden-file policy.

## License

MIT — see `LICENSE`. © 2026 Nikolas Britton.
