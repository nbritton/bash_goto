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
| compile-time diagnostics | yes | no |
| speed | normal bash speed | slow (trap fires before every command) |
| footprint | none at runtime | owns the DEBUG trap and `extdebug` |

## Requirements and installation

GNU bash **5 or newer** — both runtimes check and refuse older bash with a
clear error. Verified on 5.2.21 and 5.3.0. Neither runtime forks a single
external command, so there are no other dependencies.

Nothing to build:

```
git clone https://github.com/nbritton/bash_goto
cd bash_goto
make test            # run the QA suite (371 checks)
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
| `gosub NAME` … `ret` | call/return with a real return stack. `gosub` must be top-level; `ret` can be anywhere. |

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

**Pass 2 — masking.** Quoted regions and heredoc bodies are replaced with `X`,
preserving offsets and newlines. This is why `echo done`, a string spanning
lines that contains the word `label`, and a heredoc containing `goto nowhere`
are all correctly inert.

**Pass 3 — scan and validate.** A small tokenizer walks each masked line
tracking command position, because `do` and `done` are only keywords as the
first word of a command (`echo do` must not count). It maintains loop depth,
rewrites each `goto`, and rejects the things that cannot work.

**Pass 4 — emit.** Segments between labels become `case` branches:

```bash
declare -g __GOTO_SHELL=$BASHPID __GOTO_PC=__gt_entry
declare -ga __GOTO_STACK=()
declare -g __GOTO_RC=0
while :; do
  case $__GOTO_PC in
    (__gt_entry)
      __GOTO_PC=skip          # fall through to the next segment
      echo line 1;
      { __GOTO_PC=skip; ...; continue 1; }
      echo "you will never see this";
      __GOTO_RC=$?            # so falling off the end keeps $?
      ;;
    (skip)
      __GOTO_PC=__gt_END
      echo line 3
      __GOTO_RC=$?
      ;;
    (__gt_END) break ;;
    (*) printf "goto: no such label: %s\n" "$__GOTO_PC" >&2; exit 2 ;;
  esac
done
(exit "$__GOTO_RC")
```

Each branch sets the pc to the *next* segment before running, so falling off the
end of a segment falls through to the following label, exactly like C. Each
code segment records its last command's status, and the final line replays it,
so the compiled program's exit status matches what plain bash would give.

`goto X` compiles to `{ __GOTO_PC=X; continue N; }`, where **N is the lexical
loop-nesting depth plus one**, computed at compile time. That is what makes a
jump out of two nested `for` loops work: it emits `continue 3`. Wrapping the
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

This is checked at run time rather than statically because `( ... )`, `$( ... )`
and pipelines are exactly the constructs a line-oriented scan gets wrong, and
`BASHPID` answers the question exactly.

## Limitations

* **Labels must be at the top level of the program.** You cannot jump into the
  middle of a loop, a function, or a `{ ; }` block — the `case` branch would not
  be syntactically complete. C forbids most of this too.
* **`goto` is function-local**, as in C. Use `goto_trap.sh` if you need to jump
  out of a called function.
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
* An empty program (nothing after the `source` line) is a syntax error, not a
  no-op.
* Two heredocs on one line (`cmd <<A <<B`) can produce a spurious compile
  error (the first line of B's body is briefly scanned as code) — never
  silent misbehavior.
* `-E` output runs standalone only when the program doesn't use `gosub`/`ret`
  (those reference `__gt_ret` from goto.sh).
* `goto_trap.sh` indexes duplicate labels silently (last one wins); the
  compiler rejects duplicates.

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
test/t0*.sh                              sanity, style lint, unit,
                                         diagnostics, functional, regression
test/golden/                             pinned outputs and emitted code
test/fixtures/                           frozen inputs for regression tests
man/goto.sh.1                            the manual page
Makefile                                 test / lint / install / uninstall
bash-style-guide.md                      the style rules t02 enforces
CHANGELOG.md, CONTRIBUTING.md, LICENSE   release history, dev guide, MIT
```

Run them with `bash examples/01_forward_and_backward.sh`, and add
`GOTO_EMIT=1` to see the generated trampoline for any of them.

## Testing

```
test/run_tests.sh              # the whole suite (exits nonzero on failure)
test/run_tests.sh style        # just the files matching "style"
```

The suite is 371 assertions: a mechanical style-guide lint (which the
test files themselves must pass), unit tests for each compiler pass,
every diagnostic and invocation mode, and byte-exact goldens for the
emitted trampolines — including emissions of style-variant fixture
sources, so code generation cannot drift unnoticed. `CHANGELOG.md`
carries the release history and known limitations; `CONTRIBUTING.md`
explains the golden-file policy.

## License

MIT — see `LICENSE`. © 2026 Nikolas Britton.
