# we — Architecture

## Overview

`we` is a bash profile manager. It lets you create **named profiles** that
each hold their own aliases and functions. You step into a profile by typing
its name; the profile runs as a child bash that inherits your current shell
state. Aliases and functions you create inside the profile are persisted and
restored the next time you enter it.

The entire engine is two files:

| file | role |
|---|---|
| `we` | main script, sourced from `~/.bashrc`. Defines `we`, `we_enter`, `_we_switch`, profile registration, snapshot/restore, rcfile rendering, lifecycle cleanup. |
| `funcs.sh` | profile tools (`walias`, `wcd`, `wfunc`), persistence helpers, exit-save, session cleanup, shared-history sync. Sourced by both the base shell and every profile subshell. |

All runtime data lives under `$WE_DIR` (default `~/.we`).

---

## File layout

```
~/.we/
  we                  main script (sourced at login)
  funcs.sh            profile tools + persistence helpers
  we_alias            base aliases (optional, active in every shell)
  we_func             base functions (optional, active in every shell)
  we_<name>           profile setup script (user-editable)
  we_<name>_alias     persisted aliases for profile <name>
  we_<name>_func      persisted functions for profile <name>
  state/              transient per-session files (auto-managed)
    base_<sid>.vars   base shell variable snapshot
    base_<sid>.funcs  base shell function snapshot
    base_<sid>.aliases base shell alias snapshot
    base_<sid>.shopt  base shell shopt snapshot
    base_<sid>.cwd    base shell working directory
    rc_<prof>_<sid>   generated rcfile for a profile session
    <sid>.pre         alias baseline at profile entry
    <sid>.cur         alias state at profile exit
```

---

## Core data flow

### 1. Source time (base shell)

When `~/.bashrc` runs `source ~/.we/we`:

1. `WE_DIR` is set (default `~/.we`), `state/` is created.
2. A 1-day sweep removes orphaned `state/` files (`find -mmin +1440 -delete`).
3. `funcs.sh` is sourced → `walias`, `wcd`, `wfunc` become available in the
   base shell (they persist to `we_alias` / `we_func`).
4. `we_alias` and `we_func` are sourced (base aliases/functions active
   everywhere).
5. `_we_history_install` chains `_we_hist_sync` into `PROMPT_COMMAND`
   (shared history, see below).
6. `_we_register_all_profiles` defines a bash **function** for each existing
   profile: `foo() { we_enter 'foo'; }`. Functions are used (not aliases) so
   profile names never clash with user aliases.
7. If the user has no `EXIT` trap, `_we_base_cleanup` is installed to remove
   this base shell's `base_*` snapshot files on exit.

### 2. First entry (base → profile)

Typing `foo` in the base shell calls `we_enter foo`:

1. **Root snapshot** is taken: the base shell's variables, functions,
   aliases, shopt state, and working directory are written to
   `state/base_<sid>.*`. The sid is `<BASHPID>_<PID>` — stable for the
   lifetime of the base shell, so re-entry refreshes the same files.
2. A **rcfile** is rendered (`state/rc_foo_<sess_sid>`) that:
   - restores the base snapshot (vars, funcs, aliases, shopt, cwd)
   - runs `history -c` + `history -r` (shared history)
   - takes an alias baseline (`state/<sid>.pre`)
   - sources `we_foo` (profile setup) and `we_foo_alias` (persisted aliases)
   - sources `we_foo_func` (persisted functions)
   - sources `funcs.sh` (profile tools)
   - installs `_we_hist_sync` into `PROMPT_COMMAND`
   - sets `PS1` to show `we:foo`
   - installs an `EXIT` trap: flush history, persist new aliases, clean up
     session files
3. A **child bash** is started: `bash --rcfile <rcfile>`. If stdin is not a
   terminal (pipes, tests), `-i` is added to force interactive mode so
   `--rcfile` is honoured.
4. On `exit`, the child's `EXIT` trap persists profile-specific aliases and
   removes the session files. The parent's `rm` is a fallback for SIGKILL.

### 3. Profile-to-profile switch (replace via exec)

Typing `bar` while inside `foo` calls `we_enter bar`, which detects
`WE_ROOT_SID` is set (we're in a profile) and delegates to `_we_switch`:

1. The outgoing profile's aliases are persisted (`_we_profile_exit_save`).
2. The outgoing session's files are removed.
3. `history -a` flushes the outgoing profile's commands (the `EXIT` trap
   won't fire on `exec`).
4. A new rcfile is rendered that restores the **base** snapshot (base state,
   not `foo`'s state).
5. `exec bash --rcfile <new_rc>` replaces the process. The same PID becomes
   the new profile.

Key properties:
- **Replace, not nest**: `foo → bar` is an `exec`, not a child process.
  `exit` from `bar` goes to the base shell, not back to `foo`.
- **Base state, not intermediate**: the new profile restores the base
  snapshot, so `bar` sees the base environment, not `foo`'s modifications.
- **Generation counter**: `WE_SESSION_GEN` increments on every switch so
  session files (`rc_*`, `*.pre`, `*.cur`) stay unique across `exec`'d
  sessions (which preserve the PID).

### 4. Exit and cleanup

Three layers of cleanup:

| layer | what | when |
|---|---|---|
| child `EXIT` trap | persist aliases, remove `rc_*`, `*.pre`, `*.cur` | every profile exit |
| parent `rm` fallback | remove the same files | after `bash --rcfile` returns (covers SIGKILL) |
| base `EXIT` trap | remove `base_*` files | base shell exit (only if user has no own `EXIT` trap) |
| 1-day sweep | `find state/ -mmin +1440 -delete` | every source of `we` (backstop) |

---

## Persistence model

### Aliases

- **`walias <name> <value>`**: creates the alias in the current shell and
  immediately upserts it into the target file (`we_<prof>_alias` or
  `we_alias`). Upsert = remove old line for this name, append new line.
  Atomic via `mktemp` + `mv`.
- **`walias -d <name>`**: removes the alias from the live shell (`unalias`)
  and from the persistence file (grep-v + atomic `mktemp`/`mv`). Non-existent
  names are handled gracefully.
- **`wcd <name>`**: shorthand for `walias <name> "cd '<current dir>'"`.
  The path is single-quoted so spaces survive.
- **Plain `alias`**: not persisted eagerly. On profile exit, the `EXIT` trap
  diffs the live alias table against the baseline taken at entry
  (`*.pre` vs `*.cur`) and persists only the **new** names. This means
  session-only aliases (defined with plain `alias`) are captured, while
  aliases inherited from the base are not duplicated.
- **Base aliases are universal**: a `walias` in the base shell persists to
  `we_alias` and is inherited by every profile via the base snapshot. A
  profile can shadow a base alias: `walias` in the profile persists a
  per-profile override; plain `alias` is session-only.

### Functions

- **`wfunc <name> <body>`**: defines the function via `eval` and persists
  the canonical `declare -f` output to the target file (`we_<prof>_func`
  or `we_func`). The `declare -f` form is re-source safe (quoting, arrays,
  attributes preserved). Upsert removes the old block (from `name ()` to
  the closing `}` at column 0) and appends the new one.
- **`wfunc -d <name>`**: removes the function from the live shell
  (`unset -f`) and from the persistence file (block-stripper + atomic
  `mktemp`/`mv`). Non-existent names are handled gracefully.
- **Profile functions** are isolated to that profile. **Base functions**
  are universal (same model as base aliases).
- **Name collision with a profile**: bash gives functions precedence over
  commands, so a function named `foo` shadows the profile entry command.
  `wfunc` warns at definition time. No blocking — the user's choice.

### Danger check

`walias` and `wfunc` scan the value (or function body) for dangerous command
patterns before creating anything. Two tiers:

**Hard block** (refused outright, no confirmation):

| pattern | reason |
|---|---|
| `rm` targeting `/`, `~`, `/*`, `*`, `%` | deletes root filesystem, home, or all files |
| `mkfs` (any variant) | formats a block device, destroys all data |
| `dd … of=/dev/` | raw write to a block device |
| `:() {` | fork bomb, DoS |
| `mv /dev/null` | overwrites any file with empty content |
| `> /dev/sd*`, `nvme*`, `hd*`, `xvd*`, `mmcblk*` | raw device truncate |
| `find / … -delete` | mass deletion from root |

**Confirm** (requires uppercase **Y**):

| pattern | reason |
|---|---|
| `rm -r` / `rm -rf` (any other target) | recursive deletion, no undo |
| `chmod -R` | recursive permission change |
| `find … -delete` (not from `/`) | mass deletion |
| `dd` (without `of=/dev/`) | raw block copy |
| `shutdown` / `reboot` / `halt` / `poweroff` | system power command |

The check runs once at creation time (no runtime overhead). It is a nudge,
not a security boundary — the user has full shell access and can type any
command directly. `WE_DANGER_AUTOCONFIRM` env var skips the interactive
prompt: `Y` = auto-confirm, anything else = auto-cancel, unset = interactive.

### Profile setup script

`we_<name>` is a plain bash script sourced in the profile subshell after
the parent state is restored. It typically contains `cd`, `source
venv/bin/activate`, `echo` banners, etc. The user edits it freely.

---

## Shared history (A2)

All `we`-managed shells share one `$HISTFILE` (default `~/.bash_history`).

**Mechanism:**

- `_we_hist_sync` runs `history -a` (append new lines to file) +
  `history -n` (read lines added by other shells). Chained into
  `PROMPT_COMMAND` via `_we_history_install` (idempotent, handles both
  string and array forms, never clobbers an existing `PROMPT_COMMAND`).
- At profile startup: `history -c` (clear the stale in-memory history that
  bash loaded from the default `HISTFILE` at process start) + `history -r`
  (load the full shared history).
- Before `exec`-based switching and on profile exit: `history -a` flushes
  the outgoing shell's commands.

**Non-intrusive**: only adds per-prompt `history` builtin calls. Never
touches parsing, expansion, execution, `HISTSIZE`, `HISTFILESIZE`, or
`HISTCONTROL`.

**Key insight**: the live cross-terminal sharing works via `history -n` in
`_we_hist_sync` (called at every prompt), not via `history -r` (which is
only a one-time bulk load at startup). This means a command typed in one
terminal appears in another terminal's history at the next prompt, even
without a profile entry/exit.

---

## Design decisions

### Why functions, not aliases, for profile entry commands

v1 used aliases (`alias ai='. ~/.we/we_ai ; source ...'`). Problems:
- Aliases are expanded before commands, so a user alias with the same name
  would silently shadow the profile entry.
- Aliases don't work in scripts or non-interactive shells.
- `unalias -a` (used by v1 to clean up) is destructive.

v2 uses functions: `foo() { we_enter 'foo'; }`. Functions have lower
precedence than aliases (so a user alias can intentionally shadow a profile
name), work in all contexts, and are cleanly removable with `unset -f`.

### Why a base snapshot, not per-entry snapshots

The first design took a fresh snapshot on every profile entry. This broke
profile-to-profile switching: `foo → bar` would restore `foo`'s state
instead of the base state. The base snapshot is taken **once** on the first
entry from the base shell and is what every profile (and every switch)
restores from. This gives the correct "replace" semantics: `bar` always
sees the base environment.

The base snapshot is keyed to the base shell's PID (`<BASHPID>_<PID>`), so
re-entry from the same base shell refreshes the same files (no accumulation).
A new base shell (new terminal) gets a new sid.

### Why `exec` for switching, not a child process

A child process would nest: `foo → bar` would be a child of `foo`, and
`exit` from `bar` would return to `foo`. The user wanted replace semantics:
`exit` from `bar` goes to the base. `exec` replaces the process, so the
nesting depth stays at one. The base shell's `wait` is unaffected.

The trade-off: `exec` doesn't run the `EXIT` trap, so the outgoing profile
must persist its aliases and flush history **before** the `exec`.

### Why a generation counter

`exec` preserves the PID, so the session sid (`<base_sid>_g<gen>`) would
collide across switches without the generation counter. `WE_SESSION_GEN`
increments on every switch, keeping session files unique.

### Why `shopt -s extglob` during snapshot parsing

Functions sourced from the parent may contain extglob patterns (e.g.
bash-completion). Parsing them with extglob off is a syntax error. The
rcfile forces `shopt -s extglob` before sourcing the snapshots, then
restores the parent's exact shopt state. This was a real bug encountered
during development (the "extglob syntax error" fix).

### Why the `EXIT` trap is only installed if the user has none

Chaining `EXIT` traps in bash is fragile (the old trap is lost unless you
manually capture and re-invoke it). `we` checks `trap -p EXIT` before
installing `_we_base_cleanup`. If the user has their own `EXIT` trap, `we`
skips the install and relies on the 1-day sweep for cleanup.

### Why `mktemp` + `mv` for file writes

All persistence writes (alias upsert, func upsert, exit-save) use
`mktemp` in the same directory + `mv` (atomic rename on the same
filesystem). This prevents partial writes if the shell is killed mid-write.

### Why `compgen -v` for variable snapshotting

`compgen -v` lists every shell variable name, including ones with
characters that would break parameter expansion or array subscripts.
Iterating with `for v in "${!@}"` or `set` would miss or mangle these.

### Why `declare -p` for variable snapshotting

`declare -p <name>` produces a re-source safe line
(`declare -x name=value`, `declare -ar name=(...)`, etc.) that preserves
attributes (exported, readonly, array, associative). Plain `name=value`
would lose attributes.

### Why `declare -f` for function persistence

`declare -f <name>` produces the canonical function definition, which is
re-source safe. It preserves quoting, arrays, attributes, and the exact
function body. Storing the user's raw input would be fragile (quoting,
multi-line, special characters).

### Why the profile subshell doesn't read `~/.bashrc`

The profile is started with `bash --rcfile <rcfile>`, which replaces the
normal rcfile. System bashrcs (`/etc/bash.bashrc`, `~/.bashrc`) are NOT
read. This is intentional: the profile should see exactly what it inherited
from the parent shell plus its own files. Reading `~/.bashrc` would
re-source `we` (harmless but wasteful) and could re-define things the
profile has already set up.

### Why `HISTFILE` is not exported

If `HISTFILE` were exported, the exec'd profile bash would inherit it and
read it at startup — before the rcfile runs. This would load the wrong
history (the default `~/.bash_history` if `HISTFILE` isn't set yet, or a
stale version). By keeping `HISTFILE` non-exported, the exec'd bash uses
the default at startup, and the rcfile's `history -c` + `history -r`
correctly loads the shared history after the base snapshot restores
`HISTFILE`.

---

## Pitfalls encountered

### 1. Extglob syntax error

**Symptom**: entering a profile with bash-completion loaded caused a
"syntax error near unexpected token" in the child shell.

**Cause**: bash-completion defines functions containing extglob patterns
(e.g. `..?(/*)`). The child shell had extglob off (default), so parsing
these functions was a syntax error.

**Fix**: the rcfile forces `shopt -s extglob` before sourcing the function
snapshot, then restores the parent's exact shopt state.

### 2. `HISTFILE: unbound variable` under `set -u`

**Symptom**: sourcing `we` in a shell with `set -u` failed with
"HISTFILE: unbound variable".

**Cause**: the rcfile template (an unquoted heredoc in `_we_render_rc`)
contained `$HISTFILE` in a comment. Under `set -u`, the heredoc expansion
tried to expand `$HISTFILE` before it was set.

**Fix**: removed `$` from comment text in the heredoc. Any `$VAR` in an
unquoted heredoc is subject to expansion; comments must avoid `$` or use
`\$`.

### 3. `history -r` duplication

**Symptom**: the profile's history had duplicate entries.

**Cause**: a fresh bash reads the default `~/.bash_history` at startup
(before `HISTFILE` is set by the rcfile). Then `history -r` loaded the
shared history file, duplicating entries that were in both files.

**Fix**: `history -c` before `history -r` clears the startup-read history.

### 4. `funcs.sh` lost during break-test

**Symptom**: after a `git checkout funcs.sh` to revert a test change, the
A2 additions (`_we_hist_sync`, `_we_history_install`) were lost.

**Cause**: the A2 changes were not committed before the checkout.

**Fix**: re-added the functions. Lesson: commit before break-tests.

### 5. Vacuous test assertions

**Symptom**: a test assertion passed even when the feature it tested was
disabled.

**Cause**: in an interactive shell capture, the command line is echoed into
the capture. If the command contains the test marker (e.g.
`echo "prof_sees_base=$(history | grep -c 't24_base_cmd')"`), then
`grep -q 't24_base_cmd'` matches the **command line**, not the output.

**Fix**: write results to a file, grep the file. Or use a marker that
doesn't appear in the command line.

### 6. `HISTFILE` inheritance via exec

**Symptom**: the profile shell saw the base shell's history even without
`history -r`.

**Cause**: `history -n` in `_we_hist_sync` (called via `PROMPT_COMMAND` at
the first prompt) reads new lines from `$HISTFILE` into the in-memory
history. This is the live cross-terminal sync mechanism — it works
independently of `history -r`.

**Resolution**: not a bug. The test was valid — it was testing the
`history -n` path, which is the actual live-sharing mechanism. `history -r`
is just a one-time bulk load at startup.

### 7. `set -u` and unset variables in heredocs

**Symptom**: `set -u` caused "unbound variable" errors in the rcfile
template.

**Cause**: the rcfile template is an unquoted heredoc, so all `$VAR`
references are expanded at render time. Any variable that is unset at
render time causes an error under `set -u`.

**Fix**: use `${VAR-}` (default-empty) for optional variables, or avoid
`$` in comments.

### 8. `exec` and `EXIT` traps

**Symptom**: profile aliases were not persisted when switching profiles.

**Cause**: `exec` replaces the process without running the `EXIT` trap.
The outgoing profile's aliases were lost.

**Fix**: `_we_switch` calls `_we_profile_exit_save` and `history -a`
**before** the `exec`.

### 9. `bash --rcfile` requires long option first

**Symptom**: `bash -i --rcfile <rc>` didn't work in some bash versions.

**Cause**: bash requires the long option (`--rcfile`) to come before short
options. `bash --rcfile <rc> -i` works; `bash -i --rcfile <rc>` may not.

**Fix**: always use `bash --rcfile <rc> [-i]`.

### 10. Profile name validation

**Symptom**: creating a profile named `cd` or `alias` broke the shell.

**Cause**: the profile entry function (`cd() { we_enter 'cd'; }`) shadowed
the builtin, making `cd` unusable.

**Fix**: `_we_create` refuses names that are existing builtins or commands
(`type -t` check). Names `we` and `alias` are also refused.

---

## Testing

The test harness (`test/run.sh`) runs 162 assertions across 26 test groups
(T1–T26) in a sandbox under `/tmp`. It uses `env -i` for a clean
environment and `bash --rcfile -i` for forced-interactive profile entry.

Key test groups:

| group | what |
|---|---|
| T1 | create, management, name validation |
| T2 | entry, inheritance, walias/wcd, plain alias persistence |
| T3 | re-entry restores persisted aliases |
| T4 | extglob function parse regression |
| T5 | spaces in paths |
| T6 | state/ cleanup after exit |
| T7 | `we del` |
| T8 | profile-to-profile switching (replace/exec) |
| T9 | base snapshot cleanup on base exit |
| T10 | same-profile switch (no alias doubling) |
| T11 | base snapshot deleted → switch refused |
| T12 | profile creation inside a profile |
| T13 | long switch chain (generation counter) |
| T14 | refuse to delete the current profile |
| T15 | universal base walias (A0) |
| T16 | base alias change seen on re-entry |
| T17 | profile override of a base alias |
| T18 | wfunc in a profile (A1) |
| T19 | base wfunc (A1) |
| T20 | per-profile isolation + multi-line body |
| T21 | wfunc name validation + profile collision |
| T22 | profile listing excludes func files |
| T23 | PROMPT_COMMAND chaining (A2) |
| T24 | history flush + cross-shell sharing (A2) |
| T25 | danger check (hard block + confirm) |
| T26 | walias -d / wfunc -d (delete) |

Run: `bash test/run.sh` (exit 0 = all green).

---

## Version history

| version | changes |
|---|---|
| 2.0 | initial v2 engine (base snapshot, exec switching, lifecycle) |
| 2.1 | edge cases & hardening (extglob fix, name validation, state sweep) |
| 2.2 | A0 (universal base walias), A1 (wfunc), A2 (shared history) |
| 2.3 | danger check (walias/wfunc safety scan), walias -d / wfunc -d (delete) |
