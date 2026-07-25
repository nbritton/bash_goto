# Security policy

## What this tool is

`goto.sh` is a source-to-source compiler that **evaluates the program text
you give it**. `goto_trap.sh` does the same by re-evaluating your script.
That is the mechanism, not an oversight.

It follows that:

* **Do not compile or run untrusted input.** Handing an untrusted program
  to `goto.sh` is exactly as dangerous as running it with `bash` — the
  compiler offers no sandbox, and none is planned.
* Compiled output is ordinary bash. Anything it can do, your shell can do.
* Neither runtime forks an external command, writes a temporary file, or
  reads anything other than the program you name, so there is no temp-file
  race or `PATH` hijack surface. Please report it if you find one.

## Reporting

Open an issue at <https://github.com/nbritton/bash_goto/issues>. If you
believe the problem is sensitive, say so in the issue without details and
a private channel will be arranged.

Please include your `bash --version` and, where relevant, the output of
`goto.sh -E prog.sh` — the compiled trampoline is usually the fastest way
to see what actually happened.
