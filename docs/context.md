# Session Context — `we` v2.2

## 1. Current Project Objective

Build a robust bash alias/function profile manager (`we`) that lets users create named profiles with isolated aliases and functions, enter them by typing the profile name, persist state across sessions, and switch between profiles with replace semantics — all managed from two sourceable bash files.

## 2. Requirements

- **Language**: bash 5.0+ (developed/tested on 5.3.9)
- **OS**: Linux (tested on the dev machine); macOS should work
- **Dependencies**: none beyond bash builtins + coreutils (`find`, `mktemp`, `install`, `grep`, `sed`, `cat`, `mv`, `rm`)
- **Entry point**: `source $HOME/.we/we` from `~/.bashrc`
- **Data dir**: `$HOME/.we` (overridable via `WE_DIR` env var before sourcing)
- **No external libraries, no Python, no compiled components**

## 3. Critical Context

### Project layout

```
/ai/gen/we/                  # git repo (origin: local, no remote yet)
  we                         # main script (597 ln), sourced at login
  funcs.sh                   # profile tools + persistence (608 ln)
  install.sh                 # installer (179 ln), fresh + update paths
  README.md                  # GitHub-ready README (205 ln)
  docs/
    architecture.md          # full architecture doc (503 ln)
    context.md               # this file
  test/
    run.sh                   # regression harness (868 ln, 162 assertions)
  .gitignore
```

### Modular structure

**`we`** (main script, sourced from `~/.bashrc`):
- `we` — CLI dispatcher (create, ls, show, del, help, -v)
- `we_enter <prof>` — first-entry (snapshot + child bash) or switch (delegates to `_we_switch`)
- `_we_switch <prof>` — profile-to-profile replace via `exec`; persists outgoing, flushes history, renders new rcfile, `exec bash --rcfile`
- `_we_render_rc <prof> <base_sid> <sess_sid> <gen> <rc>` — generates the profile rcfile (unquoted heredoc; restores base snapshot, sources profile files, installs EXIT trap, chains history sync)
- `_we_snapshot_vars` — iterates `compgen -v`, emits `declare -p` lines for non-exported, non-readonly, non-special vars
- `_we_create <name>` — creates `we_<name>`, `we_<name>_alias`, `we_<name>_func`; validates name; refuses builtin/command names
- `_we_register_profile <name>` — defines `name() { we_enter 'name'; }`; unaliases any shadowing alias
- `_we_register_all_profiles` — calls `_we_register_profile` for each existing profile
- `_we_base_cleanup <sid>` — removes `base_<sid>.*` files; installed as base-shell EXIT trap only if user has none
- `_we_valid_name <name>` — regex `^[A-Za-z0-9][A-Za-z0-9._-]*$`, rejects `we`, `alias`
- `_we_profiles` — lists profile names from `we_*` files, skips `alias`, `func`, `*_alias`, `*_func`
- `_we_list`, `_we_show <name>`, `_we_del <name>` — management commands
- `_we_help` — help text
- Source-time: creates `state/`, runs 1-day sweep, sources `funcs.sh`/`we_alias`/`we_func`, calls `_we_history_install`, registers all profiles, installs base EXIT trap, exports all functions

**`funcs.sh`** (sourced by base shell AND every profile subshell):
- `walias <name> <value>` — creates alias + upserts to target file
- `walias -d <name>` — deletes alias from shell + persistence file
- `wcd <name>` — `walias <name> "cd '<pwd>'"` (spaces-safe)
- `wfunc <name> <body>` — `eval` defines function + upserts `declare -f` block to target file
- `wfunc -d <name>` — deletes function from shell + persistence file
- `_we_danger_check <value>` — scans for catastrophic/dangerous commands; hard-blocks or asks for uppercase Y
- `_we_profile_alias_file` — echoes `we_<prof>_alias` or `we_alias`
- `_we_profile_alias_upsert <name> <value>` — atomic mktemp+mv upsert
- `_we_profile_alias_delete <name>` — atomic mktemp+mv delete
- `_we_profile_func_file` — echoes `we_<prof>_func` or `we_func`
- `_we_profile_func_upsert <name>` — block-stripper upsert (removes old `name ()` … `}` block, appends new)
- `_we_profile_func_delete <name>` — block-stripper delete
- `_we_profile_exit_save <prof> <sid>` — EXIT trap: diffs `*.pre` vs `*.cur`, persists session-new aliases
- `_we_session_cleanup <prof> <sid>` — removes `rc_*`, `*.pre`, `*.cur`
- `_we_hist_sync` — `history -a` + `history -n`
- `_we_history_install` — idempotently chains `_we_hist_sync` into `PROMPT_COMMAND` (string + array forms)

### Key data structures (in `~/.we/state/`)

| file | content | lifetime |
|---|---|---|
| `base_<sid>.vars` | `declare -p` lines for non-exported vars | base shell lifetime |
| `base_<sid>.funcs` | `declare -f` output (all functions) | base shell lifetime |
| `base_<sid>.aliases` | `alias` output (all aliases) | base shell lifetime |
| `base_<sid>.shopt` | `shopt -p` output | base shell lifetime |
| `base_<sid>.cwd` | `cd <quoted-pwd>` | base shell lifetime |
| `rc_<prof>_<sess_sid>` | generated rcfile | single profile session |
| `<sess_sid>.pre` | alias baseline at entry | single profile session |
| `<sess_sid>.cur` | alias state at exit | single profile session |

`<sid>` = `<BASHPID>_<PID>` (stable per base shell). `<sess_sid>` = `<base_sid>_g<gen>` (gen increments per switch).

### Lineage markers (exported into profile shells)

| var | meaning |
|---|---|
| `WE_BASE_SID` | base snapshot sid (absent in base shell) |
| `WE_SESSION_SID` | this session's sid |
| `WE_SESSION_GEN` | generation counter (1, 2, 3, …) |
| `WE_PROFILE` | current profile name |
| `WE_DIR` | data directory |

## 4. Current Implementation State

### All phases complete, all features working

| phase | commit | status |
|---|---|---|
| initial port | `fbcc918` | ✅ |
| Phase 0: test harness | `39959e9` | ✅ 40/40 |
| Phase 1: base snapshot + lineage | `70162b2` | ✅ 40/40 |
| Phase 2: profile switching (exec) | `764f99e` | ✅ 51/51 |
| Phase 3: lifecycle rework | `f8aa1f5` | ✅ 52/52 |
| Phase 4: edge cases & hardening | `3292ff8` | ✅ 68/68 |
| Phase 5: deploy v2.1 | `2023ed3` | ✅ |
| A0: universal base walias | `54a217b` | ✅ 81/81 |
| A1: wfunc | `f01ec14` | ✅ 106/106 |
| A2: shared history | `d2e6451` | ✅ 114/114 |
| version bump 2.2 | `c1bd020` | ✅ |
| install.sh refactor | `e3a0db0` | ✅ |
| docs (architecture + README) | `f9cb850` | ✅ |
| AI credit fix | `925ec32` | ✅ |
| security review + LICENSE | `af7f2a7` | ✅ |
| root → base rename | `f9e2f53` | ✅ 114/114 |
| danger check (walias/wfunc) | `bf36d10` | ✅ 144/144 |
| walias -d / wfunc -d | `49ad763` | ✅ 162/162 |

### Features implemented and working

- Profile create/enter/exit with full shell inheritance
- `walias`, `wcd`, `wfunc` (profile + base)
- Plain `alias` persistence on exit
- Profile-to-profile switching (replace via exec, base state restore)
- Universal base aliases/functions (inherited by all profiles)
- Profile shadowing of base aliases (walias = persistent, plain alias = session-only)
- Shared history (live cross-terminal via PROMPT_COMMAND)
- Lifecycle: per-session cleanup, base cleanup on base exit, 1-day sweep
- Name validation (rejects builtins, commands, `we`, `alias`)
- Spaces-in-paths support
- Extglob function parse safety
- install.sh: fresh install + update with confirmation

### Deployed state

- `/home/m/.we` has **v2.2** (all A phases)
- Backups: `/home/m/.we.bak.20261116-184850`, `/home/m/.we.bak.20261117-160827`, `/home/m/.we.bak.20261123-153047`
- 21 real profiles migrated from v1
- `~/.bashrc` sources `$HOME/.we/we`

### Nothing in progress, nothing blocked

## 5. Testing

- **Harness**: `test/run.sh` (862 ln, 162 assertions, 26 test groups T1–T26)
- **Run**: `env -i PATH="$PATH" HOME=/tmp bash test/run.sh` (exit 0 = all green)
- **Sandbox**: `/tmp/we_sandbox` (auto-created, auto-cleaned)
- **Method**: `env -i` for clean env; `bash --rcfile <rc> -i` for forced-interactive profile entry; inner scripts fed via stdin; output captured to file; ANSI-stripped grep for assertions
- **Key pattern**: write results to a file, grep the file (avoids vacuous matches from command-line echo in interactive capture)
- **Current**: 162/162 green

| group | tests | what |
|---|---|---|
| T1 | 9 | create, management, name validation |
| T2 | 12 | entry, inheritance, walias/wcd, plain alias |
| T3 | 6 | re-entry |
| T4 | 4 | extglob function parse |
| T5 | 2 | spaces in paths |
| T6 | 3 | state cleanup |
| T7 | 2 | we del |
| T8 | 11 | profile switching |
| T9 | 1 | base cleanup on base exit |
| T10 | 4 | same-profile switch |
| T11 | 2 | base snapshot deleted |
| T12 | 3 | create inside profile |
| T13 | 5 | long switch chain |
| T14 | 2 | del current profile guard |
| T15 | 5 | universal base walias |
| T16 | 2 | base alias change on re-entry |
| T17 | 6 | profile override of base alias |
| T18 | 5 | wfunc in profile |
| T19 | 6 | base wfunc |
| T20 | 6 | per-profile isolation + multi-line |
| T21 | 4 | wfunc name validation + collision |
| T22 | 3 | profile listing excludes func files |
| T23 | 5 | PROMPT_COMMAND chaining |
| T24 | 3 | history flush + cross-shell sharing |
| T25 | 30 | danger check (hard block + confirm) |
| T26 | 18 | walias -d / wfunc -d (delete) |

## 6. Files Modified/Created

- `we` — main engine script (597 ln): all core logic (entry, switch, snapshot, rcfile, lifecycle, CLI)
- `funcs.sh` — profile tools (608 ln): walias, wcd, wfunc, danger check, persistence, exit-save, history sync
- `install.sh` — installer (179 ln): fresh install + update with confirmation, v1 migration
- `test/run.sh` — regression harness (868 ln): 162 assertions, 26 test groups
- `README.md` — GitHub-ready README (205 ln): features, install, usage, AI credit
- `docs/architecture.md` — architecture doc (503 ln): data flow, design decisions, pitfalls
- `docs/context.md` — this file: session bootstrap context
- `.gitignore` — ignores `state/`, `*.bak.*`, temp files

## 7. Constraints and Preferences

### Hard constraints

- **Two-file engine**: all logic in `we` + `funcs.sh`. No external dependencies.
- **Sourceable**: `we` must be sourceable (not executed). Uses `return 0` not `exit 0`.
- **No EXIT trap clobbering**: never overwrite a user's existing EXIT trap. Check `trap -p EXIT` first.
- **Atomic file writes**: all persistence uses `mktemp` + `mv` (same filesystem).
- **`bash --rcfile` long option first**: `bash --rcfile <rc> -i`, NOT `bash -i --rcfile <rc>`.
- **Unquoted heredoc in `_we_render_rc`**: all `$VAR` in the heredoc is expanded at render time. Comments must NOT contain `$` (use `\$` or avoid). Under `set -u`, unset `$VAR` in heredoc = fatal error.
- **`HISTFILE` must NOT be exported**: if exported, exec'd bash inherits it and reads it at startup before the rcfile runs, causing duplicate/stale history.
- **`shopt -s extglob` before sourcing function snapshots**: functions from parent may contain extglob patterns; parsing with extglob off = syntax error.
- **Profile names**: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, not `we`, not `alias`, not an existing builtin/command.
- **`compgen -v` for variable iteration**: robust against names with special characters.
- **`declare -p` for variable snapshot**: preserves attributes (exported, readonly, array, associative).
- **`declare -f` for function persistence**: canonical, re-source safe form.

### Pitfalls (encountered and fixed)

1. **Extglob syntax error**: fixed by forcing `shopt -s extglob` during snapshot parse.
2. **`HISTFILE: unbound variable`**: `$HISTFILE` in heredoc comment expanded under `set -u`. Fixed by removing `$` from comments.
3. **`history -r` duplication**: fresh bash reads default `~/.bash_history` at startup. Fixed by `history -c` before `history -r`.
4. **Vacuous test assertions**: command-line echo in interactive capture matches grep. Fixed by writing results to a file.
5. **`exec` skips EXIT trap**: must persist aliases + flush history BEFORE `exec`.
6. **`set -u` in heredocs**: use `${VAR-}` for optional vars.
7. **Profile name = builtin**: `cd() { we_enter 'cd'; }` shadows the builtin. Fixed by refusing builtin/command names.
8. **`funcs.sh` lost during break-test**: `git checkout` reverted uncommitted changes. Lesson: commit before break-tests.
9. **`HISTFILE` inheritance via exec**: non-exported `HISTFILE` is NOT inherited by exec'd bash. The profile gets it from the base snapshot. `history -n` in `_we_hist_sync` (via PROMPT_COMMAND) is the actual live-sharing mechanism, not `history -r`.
10. **PROMPT_COMMAND array form** (bash 5.1+): must handle both `declare -a` and string forms.

### Development preferences

- Git for version control; each phase committed separately.
- Sandbox-first testing (`/tmp/we_sandbox`) before deploying to `~/.we`.
- Deploy to `~/.we` only when all tests are green.
- `env -i` for clean test environments.
- Phase naming: Phase 0–5 for core, A0–A2 for features.

## 8. Exact Next Immediate Steps

1. **Push to GitHub** (no remote configured yet):
   ```bash
   cd /ai/gen/we
   git remote add origin git@github.com:<user>/we.git
   git push -u origin main
   ```

2. **Verify GitHub rendering**: open the repo URL, check README.md renders correctly (tables, code blocks, links to `docs/architecture.md`).

## 9. Any Other Aspects

- **Git repo**: `/ai/gen/we`, branch `main`, 19 commits, no remote configured.
- **Deployed**: `/home/m/.we` has v2.2. 21 real profiles. `~/.bashrc` sources it.
- **Backups**: 3 backups in `/home/m/` (`.we.bak.*`).
- **Real profiles** (21): ai, cflow, cofi, cofiw, ctab, dbg3, foo, idea, it, itax, maths, mock, mu, music, nws, os, pos, sc, u, ub, wind.
- **Real base aliases**: 9 in `~/.we/we_alias`.
- **State dir**: `~/.we/state/` — should be empty when no profiles are active.
- **Contaminated tool environment**: the persistent tool shell may have `WE_PROFILE=ai`, `WE_SESSION_SID`, `WE_BASE_SID` set. Use `env -i` or `unset` for clean tests.
- **Python venv**: `/ai/.venv/bin/python` is the designated Python environment (not used by `we` itself, but required by the harness).
- **AI credit**: developed using Qwen 3.8 27B inside Pi Coding Agent, cross-referencing a v1 prototype.
- **The v1 prototype** lived in `~/.we` before the v2 rewrite. It used aliases for profile entry, `unalias -a` for cleanup, and rewired the current shell in place. v2 replaced all of this with functions, child bash, and snapshot/restore.
- **install.sh migration**: handles v1→v2 migration (strips v1 boilerplate from profile scripts, removes legacy entry aliases from `we_alias`). Only runs on update path, not fresh install.
- **No CI/CD configured**: tests are run manually via `bash test/run.sh`.
- **No remote git repo**: the repo is local-only at `/ai/gen/we`. Pushing to GitHub is the immediate next step.
