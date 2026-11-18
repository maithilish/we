# we - work-env alias profiles

`we` lets you keep frequently-used aliases in **named profiles**. Each
profile is a shell you can step into and out of; aliases you create inside
it are persisted and automatically loaded the next time you enter it.

## Quick start

```bash
# one-time install (backs up an existing ~/.we, migrates v1 profiles)
bash install.sh

# in any new shell:
we foo                 # create profile foo
foo                    # enter the foo subshell
walias b /x/.venv/bin/python     # profile alias: b -> python
cd /x/y/z
wcd m                  # profile alias: m -> cd /x/y/z
alias g2 'llama-server -m ...'   # plain aliases work too
exit                   # back in the normal shell; everything persisted

foo                    # re-enter: b, m, g2 are all there
we ls                  # list profiles
we show foo            # inspect foo's setup + aliases
we del foo             # delete foo
```

## How it works

* `~/.bashrc` (or `~/.profile`) contains `source $HOME/.we/we`.
* Sourcing defines the `we` command and one **function per existing profile**
  (e.g. `foo`). No login-time aliases are used, so profile names never clash
  with your normal aliases.
* Running `foo`:
  1. snapshots the current shell's exported variables, local variables,
     functions and aliases into `$HOME/.we/state/`;
  2. starts a **child bash** with a private rcfile that restores that
     snapshot, then executes `~/.we/we_foo` (profile setup) and
     `~/.we/we_foo_alias` (profile aliases), and defines `walias`/`wcd`;
  3. on `exit`, an EXIT trap diffs the live aliases against the baseline
     taken in step 2 and persists only the profile-specific ones to
     `~/.we/we_foo_alias` atomically.
  The parent shell is untouched (unlike v1, which rewired the current
  shell in place via `unalias -a`).
* The prompt inside a profile shows `we:<name>`.

## Switching profiles (replace, not nest)

Typing a profile name **from inside another profile** switches to it in
*replace* style:

* The outgoing profile's session aliases are persisted first.
* The new profile restores the **base** shell state (the snapshot taken at
  first entry), *not* the outgoing profile's state. So `foo -> bar` gives you
  a clean `bar` with your base environment, and `bar`'s `exit` returns to the
  base shell (not back to `foo`).
* The switch is an `exec`: the same process becomes the new profile, so the
  nesting depth stays at one and the base shell's `wait` is unaffected.
* The new profile starts in the base working directory.

If the base snapshot is missing (e.g. it was cleaned up), the switch is
refused with a message; `exit` to the base shell and re-enter instead.

## Commands inside a profile

| command | effect |
|---|---|
| `walias <name> <value>` | create alias + persist it (value may be a multi-command string in quotes) |
| `wcd <name>` | alias `<name>` -> `cd <current dir>` (spaces-safe) |
| `alias <name>='<cmd>'` | plain aliases are persisted on exit too |
| `exit` | leave the profile; persists aliases |

`walias`/`wcd` are also available in the **base** shell; there they persist
to the base alias file `~/.we/we_alias` instead.

## Base aliases are universal

A `walias` set in the **base** shell is inherited by *every* profile and
survives profile-to-profile switches:

```
$ walias n nano        # in the base shell
$ foo                  # enter foo
$ type n               # alias n='nano'   (inherited)
$ bar                  # switch to bar
$ type n               # alias n='nano'   (still inherited)
```

How it works: on every first entry from the base shell, `we` snapshots the
base shell's full alias table into a root snapshot; every profile (and every
switch) restores from that snapshot. So base aliases flow into all profiles
automatically. Consequences:

* A base alias is persisted to `~/.we/we_alias` and is **not** copied into
  any profile's `we_<name>_alias` (the profile's exit-save skips names that
  already came from the base).
* Change a base alias and re-enter a profile, and the profile sees the new
  value (the snapshot is re-taken on each entry from the base).

### Shadowing a base alias from a profile

A profile may define an alias with the same name as a base alias. What
persists depends on how you define it:

| method in the profile | effect |
|---|---|
| `walias n '<cmd>'` | the shadow **persists** for that profile and wins on re-entry (a per-profile override of the base value) |
| `alias n='<cmd>'` | the shadow is **session-only**; the base value is restored on re-entry |

The base value in `~/.we/we_alias` is never modified by a profile shadow, so
other profiles that don't shadow it keep seeing the base value.

## Files

| file | purpose |
|---|---|
| `~/.we/we` | main script, sourced at login |
| `~/.we/funcs.sh` | `walias`/`wcd` + persistence helpers |
| `~/.we/we_alias` | base aliases for every shell (optional) |
| `~/.we/we_<name>` | profile setup script (cd, echo, venv activation, ...) |
| `~/.we/we_<name>_alias` | persisted aliases of profile `<name>` |
| `~/.we/state/` | per-session snapshots & rcfiles (auto-cleaned, don't edit) |
| `~/.we.bak.<ts>` | backup made by install.sh when upgrading |

## v1 -> v2 migration (what install.sh does)

* v1 profile scripts (`we_realias`, `unalias -a`, self-sourcing boilerplate)
  are stripped; your own lines (`cd /x`, `source venv/bin/activate`, `echo`
  banners, ...) are kept in `we_<name>`.
* v1 entry aliases in `we_alias`
  (`alias ai='. /home/m/.we/we_ai ; source ...'`) are removed - v2 uses
  functions instead.
* Everything else (your aliases, profile data) is preserved; a full backup
  is created first.

## Notes & limits

* Profile names: start with a letter/digit, then `[A-Za-z0-9._-]`; not
  `we`, `alias`, and not the name of an existing shell command/builtin.
* A profile subshell is a child bash started with `--rcfile`, so system
  bashrcs (`/etc/bash.bashrc`, `~/.bashrc`) are NOT read in it - the
  profile only sees what it inherited from your shell plus its own files.
* Re-sourcing `~/.we/we` is safe and idempotent.
* `WE_DIR` can be set before sourcing to relocate the whole thing.
* Lifecycle: each profile session removes its own `state/` files on exit;
  the base shell removes its `root_*` snapshot on exit (only if you have no
  EXIT trap of your own). A 1-day sweep at source time is the backstop for
  shells that die without running their traps.
* Edge cases: switching to the profile you are already in gives a fresh
  session (no alias doubling); creating a profile from inside another warns
  that the entry command is only registered in this shell; `we del` refuses
  to delete the profile you are currently inside.
