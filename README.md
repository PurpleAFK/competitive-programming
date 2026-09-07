# Codeforces terminal setup — commands and workflow

Reference for the **current modular setup** in `~/cf-contests`, including the
flat-archive change, `cft`, `croot`, and `cfclean`. No `cf-shell` is needed.

## Quick reference

| Command | Action |
| --- | --- |
| `cf parse 2259` | Fetch statement samples and create the contest files |
| `cf init 2259 a b c d` | Create files offline; no samples fetched |
| `cfc 2259` | Enter the contest directory |
| `switch a` | Enter problem A and open its C++ file in Neovim |
| `croot` | Return the current shell to the setup root |
| `cf list` | List problems in the resolved contest |
| `cf test` | Compile and run sample/custom tests with the Python runner |
| `cf test --debug` | Test with sanitizers, assertions, and `LOCAL` |
| `cft` | Run the separate Bash tester, with `LOCAL` and the ACL include path |
| `cf run` | Compile and run with interactive stdin |
| `cf stress 1000 --seed 42` | Compare solution and brute on generated cases |
| `cf submit` | Compile, snapshot, copy source, and open the submission page |
| `cf diff` | Compare current source with the last prepared snapshot |
| `cf open` | Open the current problem statement in the browser |
| `archive 2259` | Archive the whole contest |
| `archive a 2259` | Archive problem A, including its tests and helpers |
| `cf restore PATH` | Restore a whole-contest archive without overwriting work |
| `cfclean 2259` | Delete the working copy of contest 2259, after confirmation |
| `cfclean all` | Clear the contents of `contests/`, after confirmation |

Problem indices are case-insensitive: `a`, `A`, `b1`, and `B1` work when present.
The navigation words `next` and `prev` are lowercase.

## Load the commands

In your existing Bash or Zsh shell:

```bash
source "$HOME/cf-contests/scripts/shell.sh"
```

For persistence, put that line **after the old CP setup/aliases** in your
`.bashrc` or `.zshrc`. The new integration replaces the in-memory `cf`, `cfc`,
`switch`, and `archive` commands. The added `cft`, `croot`, and `cfclean`
definitions must also be present in `scripts/shell.sh`.

Check which commands your shell is using:

```bash
type cf archive switch cfc cft croot cfclean
cf --version
```

Use `cf test`, `cf run`, and `cf stress`, not old bare `test`, `run`, or `stress`
aliases. `test` is also a shell builtin; `cft` avoids that name collision.

## Workspace layout

```text
~/cf-contests/
├── template.cpp
├── templates/
│   ├── brute.cpp
│   └── gen.cpp
├── scripts/
│   ├── cf
│   ├── common.py
│   ├── fetch.py
│   ├── runner.py
│   ├── stress.py
│   ├── editor.py
│   ├── archiving.py
│   ├── nvim.lua
│   ├── shell.sh
│   ├── test.sh
│   └── clean.py
├── contests/
│   └── 2259/
│       ├── .cf-contest.json
│       ├── a/
│       │   ├── a.cpp
│       │   ├── brute.cpp
│       │   ├── gen.cpp
│       │   ├── tests/
│       │   │   ├── samples/        # 01.in, 01.out, ...
│       │   │   └── custom/         # edge.in, edge.out, ...
│       │   ├── failures/           # Created after a stress failure
│       │   ├── submissions/        # Prepared source snapshots
│       │   ├── sample-backups/     # Created by sample refresh
│       │   └── .cf/                # Binaries and transient run output
│       └── b/
│           └── b.cpp
└── archive/
    ├── contests/2259/             # Whole-contest snapshot
    └── problems/2259/a/           # Problem-A snapshot
```

Other root files, such as `dependencies.md`, are unaffected by contest cleanup.
Gym working folders use `contests/gym-ID/`.

The root is derived from the location of `scripts/`. `shell.sh` exports
`CF_CONTEST_ROOT` for shell helpers. This modular version does **not** use the old
`CF_HOME` variable to relocate its workspace.

## Which contest/problem is selected

For commands supporting `--contest`:

1. An explicit `--contest ID` selects that contest.
2. Otherwise, an enclosing `.cf-contest.json` identifies the current contest.
3. Outside a contest, `.active` supplies the last parsed, initialized, or restored
   contest.

`cfc` changes directories; it does not update `.active`. Prefer `cfc ID` before
working on a contest rather than relying on the fallback after `croot`.

Commands such as `cf test` infer the problem from the working directory. At the
contest root, give an index or enter a problem first. `cf edit` and
`cf path --file` can select the first problem when no current problem is available.

Relative file arguments are relative to the command's working directory. When
running from elsewhere with `--contest`, use absolute input/checker paths.

## Help and explicit working directory

```bash
cf --help
cf --version
cf parse --help
cf test --help
cf stress --help
cf archive --help
cft --help
cfclean --help
```

Every public `cf` subcommand supports `--help`. The global `--cwd` option goes
**before** the subcommand:

```bash
cf --cwd "$CF_CONTEST_ROOT/contests/2259/a" test --debug
```

## Fetching and offline preparation

```bash
cf parse 2259
cf parse 2259 --refresh-samples
cf parse 2259 --html "$HOME/Downloads/problems.html"

cf init 2259 a b c d e f g h

cf parse 104000 --gym
cf init 104000 a b c --gym
```

- `parse` discovers the actual indices from the all-problems page; it does not
  assume A–F.
- Existing solution, brute, and generator files are never overwritten.
- Existing official samples are kept unless `--refresh-samples` is supplied.
- Refresh moves the old samples into that problem's `sample-backups/` directory.
- Custom tests are retained.
- `init` uses the indices you supply and fetches nothing. Later `parse` adds
  samples without replacing your code.
- These are statement samples, **not hidden/system tests**.

Direct fetching makes an unauthenticated HTTP request with a 20-second request
timeout. Login requirements, Cloudflare, or an unstarted contest can block it.
The fallback is to open:

```text
https://codeforces.com/contest/2259/problems?locale=en
```

Complete any login/challenge, save the **all-problems page** as HTML with Ctrl-S,
and use `--html`. Use HTML, not PDF or MHTML. Add `--gym` for a Gym page.
Private group-specific URLs/submission flows are not automated.

Parser quirk: `init --help` also lists `--html` and `--refresh-samples` because
its parser shares options with `parse`; they are not useful for offline `init`.

## Terminal navigation and browser access

```bash
cfc 2259
cfc 104000 --gym

switch a
switch b1
switch next
switch prev
switch b --contest 2259

croot

cf list
cf list --contest 2259
cf list --indices

cf edit a
cf edit b --contest 2259
cf open
cf open b --contest 2259
```

- `cfc ID`: changes the current shell's directory to the contest root.
- `switch INDEX`: changes the shell directory and opens that problem's source.
- `switch` without an index uses the current problem, or the first problem of
  the resolved contest if none is current.
- `next`/`prev` require a current problem and wrap around the problem list.
- `croot`: returns to the setup root, not the current contest root.
- `cf edit` opens Neovim but cannot change its parent shell's directory; use
  `switch` when you want both.
- In a Neovim terminal with `NVIM` set, `cf edit`/`switch` reuse the parent editor
  through RPC rather than nesting another Neovim.
- `cf open` opens a problem; at a contest root, supply its index.
- `cf list` lists the whole contest. An optional problem argument displayed in
  its help is ignored.

Path helpers for scripts:

```bash
cf path --contest 2259             # Contest directory
cf path a --contest 2259           # Problem directory
cf path a --file --contest 2259    # Solution filename
cf path next --file               # Next problem; run inside a problem
```

`cf path` inside a problem prints that problem directory. At a contest root it
prints the contest directory. Outside a contest, without explicit selectors, it
can fall back to the first problem of `.active`.

## Neovim commands and keys

Launched through `switch`/`cf edit`, Neovim loads your usual config plus the
session's contest commands. No permanent `init.lua` changes are required.

| Command | Action |
| --- | --- |
| `:Cf b` | Switch to B, retaining unsaved buffers |
| `:CfNext` | Next problem |
| `:CfPrev` | Previous problem |
| `:CfTest` | Save current problem's modified buffers; run `cf test` |
| `:CfDebug` | Save and run `cf test --debug` |
| `:CfRun` | Save, compile, and run with terminal stdin |
| `:CfRun --input tests/samples/01.in` | Run on a file |
| `:CfStress 1000 --seed 42` | Save and start stress testing |
| `:CfSubmit` | Save and prepare a browser submission |
| `:CfSubmit --no-open` | Prepare and copy without opening the browser |
| `:CfDiff` | Save and compare with the last prepared snapshot |
| `:CfOpen` | Open the statement; does not save buffers |
| `:CfOutput` | Focus/reopen the most recent runner output |

Available mappings, **only when the keys were not already mapped**:

| Key | Command |
| --- | --- |
| F5 | `:CfTest` |
| F6 | `:CfDebug` |
| `<leader>cn` | `:CfNext` |
| `<leader>cp` | `:CfPrev` |
| `<leader>cs` | `:CfSubmit` |

The default leader is backslash unless your config changes it.

Runner output appears in a bottom terminal split. Tests leave focus in your code;
interactive `:CfRun` takes terminal focus. Use `Ctrl-\ Ctrl-N` to leave terminal
input mode, then `Ctrl-W k` to return to the window above. `:CfOutput` followed
by Ctrl-C interrupts a running job. A second runner job is not started while one
is active.

Switch with `:Cf INDEX` before testing/submitting another problem. Editor runner
commands reject problem/contest selectors rather than save A and execute B's
unsaved disk copy. Flags such as `--timeout`, `--checker`, and `--exact` can be
passed to their corresponding commands.

`croot` is a shell command. Inside Neovim, this changes the tab's working directory:

```vim
:tcd ~/cf-contests
```

It does not change the source buffer; `:CfTest` still uses the selected problem.
Entering another contest C++ buffer updates the directory to that problem again.

## Build and run

Run these inside a problem, or supply an index and `--contest`:

```bash
cf build
cf build --debug
cf build b --contest 2259

cf run
cf run --debug
cf run --input tests/samples/01.in
cf run --input /tmp/input.txt --timeout 2
cf run b --contest 2259 --input /tmp/b.in
```

`build` prints the executable path. Builds are fresh on every invocation: an old
binary is not used after compilation fails. Local header changes are included.

`run` without `--input` inherits terminal stdin; Ctrl-D sends EOF and Ctrl-C
interrupts. It has no automatic run timeout/output cap. `--timeout` applies to
file-based `run` only.

Compiler timeout is 120 seconds. Automated runs use a local wall-clock timeout,
not Codeforces CPU accounting. Regular output files are capped at 16 MiB by the
Python runner, core dumps are disabled, and no memory limit is enforced. These
runners are not a security sandbox for hostile executables.

## The two testers

| Property | `cf test` / F5 | `cft` |
| --- | --- | --- |
| Implementation | Python, `scripts/runner.py` | Bash, `scripts/test.sh` |
| Default source | Current problem's main source | Nearest problem `<dirname>.cpp` |
| Other source file | Select another problem, not an arbitrary filename | Accepts any source path, e.g. `brute.cpp` |
| Test location | Selected problem's `tests/` | `tests/` beside the selected source |
| Default timeout | 3 seconds per run | 5 seconds per run |
| Default `LOCAL` | Disabled | Enabled |
| Debug mode | `--debug`, or F6 | No separate debug flag; `LOCAL` is always defined |
| ACL include | Configure compiler environment/flags | Defaults to `$HOME/contests/acl` |
| Comparison | Tokens, `--exact`, or custom checker | Tokens |
| Output/logs | Kept under the problem's `.cf/run/` | Temporary outputs removed after the run |

**F5 still runs `cf test`, not `cft`.** Adding `test.sh` does not replace the Python
backend. Both testers keep stderr separate from judged stdout and reject missing
input/answer pairs and empty test suites.

### Python tester

```bash
cf test
cf test --debug
cf test --timeout 2
cf test --exact
cf test --checker checker.cpp
cf test --checker checker.py
cf test b --contest 2259
```

Default comparison is case-sensitive, whitespace-token equality. `--exact` is
byte equality. `--checker` and `--exact` are mutually exclusive.

A checker is invoked as:

```text
checker INPUT_FILE ACTUAL_FILE EXPECTED_FILE
```

Return 0 to accept, 1 to reject, and another code for a checker error. `.cpp`
checkers are compiled; `.py` checkers use the CLI's Python; other checker files
must be executable. The checker uses the command's `--timeout` limit.

A valid constructive answer can differ from the sample. Floating-point output
may need a tolerance checker. Plain token comparison is not the Codeforces judge,
and no interactive interactor is supplied. There is no `--eps` flag in this version.

### Bash tester

```bash
cft
cft a.cpp
cft brute.cpp
cft ../b/b.cpp

# From the setup root:
cft contests/2259/b/b.cpp

CF_TEST_TIMEOUT=2 cft
ACL_DIR="$HOME/another-location/acl" cft
CXX=clang++ cft
NO_COLOR=1 cft
```

`cft` discovers `.in`/`.out` pairs recursively, supports paths with spaces, and
sorts numbered cases naturally. With no source argument it searches upwards for
a directory containing `<directory-name>.cpp` and `tests/`.

It uses `-std=c++20 -O2 -DLOCAL -Wall -Wextra -Wshadow` and the ACL include path.
Timeout escalation sends SIGKILL after one extra second if necessary. Temporary
files are private to each invocation, so simultaneous runs do not share stderr
or binaries.

Keep `LOCAL` diagnostics on `cerr`. Redirecting stdin/stdout with `freopen` in
local builds defeats the test runner's input/output redirection.

## Add custom tests

```bash
cf addtest edge --input /tmp/edge.in --output /tmp/edge.out

cf addtest edge --problem b --contest 2259 \
    --input /tmp/b-edge.in --output /tmp/b-edge.out
```

`-p` is shorthand for `--problem`. This copies files into
`tests/custom/edge.in` and `tests/custom/edge.out`; an existing name is not
overwritten. Names are 1–64 letters/digits/dots/underscores/hyphens, starting
with a letter/digit.

You can also edit test pairs directly:

```bash
nvim tests/custom/edge.in tests/custom/edge.out
cf test
```

For input without an expected answer, use `cf run --input FILE`, not `test`.

## Stress testing

First adapt `gen.cpp` to the problem's actual input format/constraints and implement
`brute.cpp` as a correct small-input oracle. The supplied generator's array format
is only an example. The unimplemented brute deliberately exits with an error.

```bash
cf stress                         # 1000 cases; starting seed 1
cf stress 5000 --seed 42
cf stress 1000 --debug
cf stress 1000 --timeout 2 --brute-timeout 20
cf stress 1000 --exact
cf stress 1000 --checker checker.cpp
cf stress 1000 -p b --contest 2259
```

- Count must be positive; the seed range must fit an unsigned 64-bit integer.
- `gen` receives each seed as `argv[1]`: 42, 43, 44, ...
- The generator and solution default to 3 seconds per run; brute defaults to 10.
- The first mismatch, crash, timeout, or helper/checker failure stops the run.
- A failure bundle is saved under `failures/TIMESTAMP-seed-N/` with available
  input/output files, diagnostics, metadata, and snapshots of the three C++ sources.
- Local included headers and checker source are not bundled automatically.

Replay a candidate failure, or add it to the regular test suite:

```bash
cf run --input failures/TIMESTAMP-seed-N/input.txt

cf addtest regression \
    --input failures/TIMESTAMP-seed-N/input.txt \
    --output failures/TIMESTAMP-seed-N/expected.txt

cf test
```

Only promote an expected answer after the brute completed successfully and you
trust the oracle. A generator/brute failure may not have usable expected/actual
output files.

## Submission preparation and diffs

```bash
cf submit
cf submit --no-open
cf submit --no-copy
cf submit --no-open --no-copy
cf submit b --contest 2259

cf diff
cf diff b --contest 2259
```

`submit`:

1. Compiles the on-disk solution in release mode, without `LOCAL`.
2. Checks that the source did not change during compilation.
3. Saves its exact bytes under `submissions/TIMESTAMP.cpp`.
4. Copies the source with `wl-copy`, unless `--no-copy` is supplied.
5. Opens the submission page, unless `--no-open` is supplied.

**Nothing is submitted automatically.** Choose the problem/language as needed,
paste, and submit in your browser. Header files are not inlined; pasted source
must be self-contained. Clipboard/browser failure does not remove the snapshot
already written.

`cf diff` compares the file on disk against the last **prepared** snapshot, not
a remotely confirmed submission. No output and exit 0 mean unchanged; exit 1
means differences. This version has no `--last-two` or `--skip-build` option.

Terminal commands cannot see unsaved editor buffers. Save first, or use
`:CfSubmit` / `:CfDiff`, which save the selected problem before running.

## Archive and restore

```bash
archive 2259                       # Entire contest
archive a 2259                     # Just A, including its helpers/tests

# Equivalent CLI forms:
cf archive 2259
cf archive a 2259

# Gym:
archive 104000 --gym
archive a 104000 --gym
```

Bare `archive` / `cf archive` archives the resolved current contest; explicit IDs
are preferable when outside a contest. Pass IDs/indices, not source-file paths.

With the flat-archive patch applied, destinations are:

```text
archive/contests/2259/
archive/problems/2259/a/
```

- Archives are verified directory copies, not moves.
- Working files are kept in place.
- Existing archive destinations are **not overwritten**. Repeating an archive
  command for the same destination fails; it does not refresh that copy.
- Preserve/move an old archive deliberately before creating a replacement.
- Included work covers sources, helpers, samples, custom tests, notes, failure
  bundles, prepared submissions, and sample backups.
- `.cf/`, `__pycache__/`, and editor swap/backup files are excluded.
- Included symlinks and special files cause an error rather than being followed.
- Save files before archiving; unsaved Neovim buffers are not part of a disk snapshot.

Timestamps still appear in submission snapshots, stress failures, and sample
backups. Removing the extra contest-archive layer did not disable those histories.

Restore a whole contest after its working copy has been removed:

```bash
cf restore "$CF_CONTEST_ROOT/archive/contests/2259"
cfc 2259
switch a
```

Restore requires a whole-contest snapshot containing `.cf-contest.json` and never
overwrites an existing working contest. Earlier inline-kit `.tar.gz` archives
with compatible metadata are also supported. Problem-only snapshots are copied
back manually; the directory restore command does not infer their identity.

There is no archive `--replace`, `--move`, or `--remove` flag in this configuration.

## Return to root and clean working files

```bash
croot

cfclean 2259
cfclean all
cfclean gym-104000

cfclean 2259 --yes
cfclean all --yes
```

`-y` is shorthand for `--yes`.

**Cleanup permanently deletes working sources and tests, including unarchived
work. It does not create an archive for you.**

- `cfclean 2259` removes `contests/2259/`.
- `cfclean all` removes all entries inside `contests/`, including hidden files
  and other non-contest entries. The `contests/` directory itself remains.
- Top-level `archive/`, `scripts/`, `templates/`, `template.cpp`, and documentation
  are not removed. Nested files inside a working contest are part of the deletion.
- The wrapper returns your current shell to the root first, even if you cancel.
- Without `--yes`, type exactly `DELETE 2259`, `DELETE all`, or the corresponding
  requested target to confirm.
- Stale `.active` selection is removed after cleanup.
- Symlink entries are unlinked, not followed. A symlinked `contests/` container
  is refused.

Save and close contest buffers, and stop tests before cleaning. Existing `cf`
locks are checked, but the standalone `cft` runner does not use those locks.
New directory entries created concurrently may be left untouched.

For a contest that does not already have an archive:

```bash
archive 2259 && cfclean 2259
```

The cleanup runs only if archiving succeeds. An existing flat archive makes the
archive command fail, so this chain will not delete the working copy in that case.

## Templates, compiler settings, and ACL

Edit `template.cpp` for new solutions, and `templates/brute.cpp` /
`templates/gen.cpp` for the helper boilerplate. Existing problem files are not
regenerated. The solution template has a single/multiple-test toggle: uncomment
`cin >> t` only when the input actually starts with a test count.

Use an existing template without modifying it:

```bash
export CF_TEMPLATE="$HOME/codeforces/template.cpp"
```

Environment variables:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `CF_CONTEST_ROOT` | Shell helpers | Set by `shell.sh` to the project root |
| `CF_TEMPLATE` | `cf parse`, `cf init` | Alternative solution template |
| `CF_CXX` | Python runner | Compiler argv, default `g++`; shell-style quoting supported |
| `CF_CXXFLAGS` | Python release builds | Replaces the complete release flag set |
| `CF_DEBUGFLAGS` | Python debug builds | Replaces the complete debug flag set |
| `CF_BROWSER` | Browser helper | Launcher argv, default `xdg-open` |
| `CXX` | `cft` | One compiler executable/path, default `g++` |
| `ACL_DIR` | `cft` | Default `$HOME/contests/acl` |
| `CF_TEST_TIMEOUT` | `cft` | Positive finite seconds, default 5 |
| `NO_COLOR` | `cft` | Suppresses its color output when set |

Python release defaults:

```text
-std=c++20 -O2 -pipe -Wall -Wextra -Wshadow
```

Python debug defaults:

```text
-std=c++20 -O1 -g -D_GLIBCXX_ASSERTIONS
-fsanitize=address,undefined -fno-sanitize-recover=all
-fno-omit-frame-pointer -Wall -Wextra -Wshadow
```

`LOCAL` is forcibly undefined for release and defined for debug, after custom flags.
The debug and release overrides are separate. Commands/flags are tokenized, not
executed as shell pipelines.

To make ACL available to both the Python runner/F5 and the Bash tester without
replacing all compiler flags, GCC supports:

```bash
export CPLUS_INCLUDE_PATH="$HOME/contests/acl${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
```

The path must contain the `atcoder/` directory. Set environment exports before
launching Neovim so its jobs inherit them. Select a compatible C++ language version
when submitting on Codeforces; local compilation is not judge-toolchain emulation.

## Complete contest workflow example

Replace `2259` with the contest you are entering. The archive step below assumes
that contest does not already occupy its flat archive destination.

### Before/start of the round

```bash
source "$HOME/cf-contests/scripts/shell.sh"
croot

# Optional before statements are available; supply the indices yourself:
cf init 2259 a b c d e f g h

# Once the all-problems page is available:
cf parse 2259
cfc 2259
cf list
switch a
```

If fetching is blocked, save the all-problems HTML in the browser, then use
`cf parse 2259 --html /path/to/problems.html` instead.

### Solve and test without leaving Neovim

```vim
" Write A, then:
:CfTest
:CfDebug
:CfRun --input tests/samples/01.in
:CfSubmit

" Paste/submit in the browser, then continue:
:Cf b
:CfTest
:Cf a
:CfDiff
```

For a difficult problem, implement `brute.cpp` and adapt `gen.cpp`, then:

```vim
:CfStress 1000 --seed 42
```

### Add a counterexample or manual case

From the problem directory in a terminal:

```bash
nvim tests/custom/edge.in tests/custom/edge.out
cf test
# Or use the separate Bash tester:
cft
```

### Finish the contest

Save and close its Neovim buffers. Stop any remaining test/stress jobs.

```bash
croot
archive 2259 && cfclean 2259
```

Confirm `DELETE 2259` when prompted. Your code and tests are now in
`archive/contests/2259/`, while the working copy is removed.

If you already have a suitable archive and only want to remove the working copy:

```bash
cfclean 2259
```

### Return later for upsolving

```bash
cf restore "$CF_CONTEST_ROOT/archive/contests/2259"
cfc 2259
switch a
```

After upsolving, the old flat archive still exists. Preserve it elsewhere before
attempting a replacement; the archive command does not silently overwrite it.

## Common failure messages

| Symptom | Check |
| --- | --- |
| `archive` behaves like the old file-based script | `type archive`; source the new `shell.sh` after old aliases |
| `cft` runs the wrong script | `type cft`; confirm the new function is installed |
| `No current problem` | `cfc ID`, then `cd a` / `switch a`, or provide an index |
| No statements / HTTP error | Contest availability/login; import saved all-problems HTML |
| No tests / missing answer | Every test needs matching `.in` and `.out` files |
| Archive destination exists | Flat archives do not overwrite; preserve the old copy first |
| Restore destination exists | Restore requires the working contest path to be absent |
| Another operation is using the contest | Wait for or stop the active `cf` job |
| F5/F6 does something else | Existing mappings were preserved; use `:CfTest` / `:CfDebug` |
| ACL header not found | Check `ACL_DIR` for `cft`, and compiler include settings for `cf test` |
| Clipboard/browser error | Check `wl-copy`, `xdg-open`/`CF_BROWSER`, and the graphical session |

Typical exit codes are 0 for success, 1 for local test/stress failure or a nonempty
`cf diff`, 2 for setup/argument/build errors, and 130 for interruption. A cleanup
cancel returns 1. Nonzero `cf diff` status can be an ordinary code difference.

Internal helper: `cf _args '<argument string>'` prints a JSON argument list for
Neovim's command parser. It is not needed in the normal workflow.
