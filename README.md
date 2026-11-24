# we — work-env profile manager for bash

Keep frequently-used aliases and functions in **named profiles**. Step into
a profile by typing its name; step out with `exit`. Everything you create
inside a profile is persisted and restored the next time you enter it.

```
$ we foo              # create profile "foo"
$ foo                 # enter the foo subshell
we:foo ~ $ walias b /x/.venv/bin/python
we:foo ~ $ cd /x/y/z
we:foo ~ $ wcd m      # m -> cd /x/y/z
we:foo ~ $ wfunc hi 'echo "hello $1"'
we:foo ~ $ exit
$ foo                 # re-enter: b, m, hi are all there
```

The parent shell is never modified. Profiles are isolated from each other.
Base-shell aliases and functions are inherited by every profile.

---

## Features

- **Named profiles** — each profile has its own setup script, aliases, and
  functions. Create with `we <name>`, enter by typing `<name>`.
- **Full shell inheritance** — a profile subshell inherits all exported
  variables, local variables, functions, and aliases from the parent shell.
- **`walias`** — create a persisted alias (profile-specific or base).
- **`wcd`** — one-shot alias to `cd` into the current directory.
- **`wfunc`** — define and persist a function (profile-specific or base).
- **Plain `alias` works too** — session aliases are captured on exit and
  persisted automatically.
- **Profile-to-profile switching** — type a profile name from inside another
  profile to switch. Replace semantics: the new profile restores the **base**
  shell state, and `exit` goes to the base (not back to the previous profile).
- **Universal base aliases/functions** — a `walias` or `wfunc` in the base
  shell is inherited by every profile and survives switches.
- **Shared history** — all `we`-managed shells share one `$HISTFILE`.
  Commands typed in any profile appear in the base shell and every other
  terminal at the next prompt. Live cross-terminal sync via
  `PROMPT_COMMAND` (never clobbers an existing one).
- **Safe lifecycle** — per-session cleanup on exit, base-snapshot cleanup on
  base-shell exit, 1-day sweep as backstop. Never clobbers a user's `EXIT`
  trap.
- **Idempotent** — re-sourcing `~/.we/we` is safe.

---

## Install

### Requirements

- bash 5.0+ (tested on 5.3)
- Linux or macOS

### From this repository

```bash
git clone <repo-url> ~/we
bash ~/we/install.sh
```

`install.sh` will:

- **Fresh install** (no `~/.we`): creates `~/.we`, copies the engine files,
  adds `source ~/.we/we` to your `~/.bashrc`.
- **Update** (`~/.we` exists): shows current vs new version, asks for
  confirmation, backs up `~/.we`, replaces the engine files, preserves your
  profile data.

Open a new terminal (or run `source ~/.we/we`) and you're ready.

### Manual install

```bash
mkdir -p ~/.we/state
cp we funcs.sh ~/.we/
echo 'source "$HOME/.we/we"' >> ~/.bashrc
```

---

## Usage

### Managing profiles

| command | effect |
|---|---|
| `we` | prompt for a name and create a profile |
| `we <name>` | create profile `<name>` |
| `we ls` | list profiles with alias/function counts |
| `we show <name>` | show profile setup + aliases + functions |
| `we del <name>` | delete a profile (with confirmation) |
| `we -v` | show version |
| `we help` | help text |

### Inside a profile

| command | effect |
|---|---|
| `walias <name> <cmd>` | create + persist an alias |
| `wcd <name>` | alias `<name>` → `cd <current dir>` |
| `wfunc <name> <body>` | define + persist a function |
| `alias <name>='<cmd>'` | plain alias (persisted on exit) |
| `exit` | leave the profile; new aliases are persisted |

`walias`, `wcd`, and `wfunc` also work in the **base** shell; there they
persist to the base files (`~/.we/we_alias`, `~/.we/we_func`) and are
available in every profile.

### Profile setup script

Each profile has a setup script (`~/.we/we_<name>`) that runs after the
parent state is inherited. Put your `cd`, `source venv/bin/activate`,
`export` lines, or `echo` banners there. Edit it freely.

---

## How it works (brief)

1. `~/.bashrc` sources `~/.we/we`, which defines the `we` command and a
   function per existing profile.
2. Typing `foo` snapshots the base shell state (vars, funcs, aliases, shopt,
   cwd) into `~/.we/state/`, renders a private rcfile, and starts a child
   bash with that rcfile.
3. The child restores the snapshot, sources the profile's setup/alias/func
   files, and gives you a prompt tagged `we:foo`.
4. On `exit`, an `EXIT` trap diffs the live aliases against the baseline and
   persists only the profile-specific ones. Session files are cleaned up.
5. Switching profiles (`foo → bar`) is an `exec`: the same process becomes
   the new profile, restoring the **base** state. `exit` from `bar` goes to
   the base shell.

See [docs/architecture.md](docs/architecture.md) for the full architecture,
design decisions, and pitfalls.

---

## Files

| file | purpose |
|---|---|
| `~/.we/we` | main script (sourced at login) |
| `~/.we/funcs.sh` | `walias` / `wcd` / `wfunc` + persistence + history sync |
| `~/.we/we_alias` | base aliases (optional) |
| `~/.we/we_func` | base functions (optional) |
| `~/.we/we_<name>` | profile setup script |
| `~/.we/we_<name>_alias` | persisted aliases for profile `<name>` |
| `~/.we/we_<name>_func` | persisted functions for profile `<name>` |
| `~/.we/state/` | per-session snapshots & rcfiles (auto-cleaned) |

---

## Notes

- Profile names: start with a letter/digit, then `[A-Za-z0-9._-]`. Cannot be
  `we`, `alias`, or the name of an existing shell command/builtin.
- A profile subshell does **not** read `~/.bashrc` or `/etc/bash.bashrc` —
  it only sees what it inherited from your shell plus its own files.
- `WE_DIR` can be set before sourcing to relocate the data directory.
- Shared history reuses your existing `$HISTFILE`; it does not create a
  separate file.
- The engine is two files (`we` + `funcs.sh`). No dependencies beyond bash.

---

## Testing

```bash
bash test/run.sh
```

114 assertions across 24 test groups. Runs in a sandbox under `/tmp`; does
not touch your real `~/.we`.

---

## AI-assisted development

This project was developed using **Qwen 3.8 27B** running inside the
**[Pi Coding Agent](https://github.com/earendil-works/pi-coding-agent)**
harness, cross-referencing an existing v1 prototype. The AI handled the
full v2 rewrite: architecture design, implementation, testing, and
documentation.

The codebase is intentionally small (two engine files, ~900 lines total) and
well-commented, making it a good candidate for further AI-assisted
development. Clone the repo, describe the feature you want, and let your
preferred AI coding assistant extend it. The test harness (`test/run.sh`)
gives immediate feedback on whether your changes broke anything.

---

## License

MIT
