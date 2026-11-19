#!/bin/bash
# ============================================================================
# install.sh - install the we v2 engine into $WE_DIR (default $HOME/.we)
#
#   - backs up any existing $WE_DIR to $WE_DIR.bak.<timestamp>
#   - installs we + funcs.sh
#   - migrates legacy (v1) profile scripts to the v2 format
#   - removes legacy entry aliases from the base alias file (we_alias)
#   - makes sure ~/.bashrc (or ~/.profile) sources $WE_DIR/we
#
# Usage: bash install.sh [target_dir]
# ============================================================================
set -u

SRC_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET=${1:-$HOME/.we}
BACKUP=""

log()  { printf 'install: %s\n' "$*"; }
warn() { printf 'install: WARNING: %s\n' "$*" >&2; }

# --- sanity checks ----------------------------------------------------------
[ -f "$SRC_DIR/we" ] && [ -f "$SRC_DIR/funcs.sh" ] || {
    printf 'install: cannot find we/funcs.sh next to install.sh (%s)\n' "$SRC_DIR" >&2
    exit 1
}
bash -n "$SRC_DIR/we" && bash -n "$SRC_DIR/funcs.sh" || {
    printf 'install: syntax check of source scripts failed\n' >&2
    exit 1
}

mkdir -p -- "$TARGET" 2>/dev/null || {
    printf 'install: cannot create %s\n' "$TARGET" >&2
    exit 1
}
[ -d "$TARGET/state" ] && log "found existing installation (v1 or v2)"

# --- backup -----------------------------------------------------------------
if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
    BACKUP="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$TARGET" "$BACKUP" || {
        printf 'install: backup to %s failed; aborting\n' "$BACKUP" >&2
        exit 1
    }
    log "backup created: $BACKUP"
fi

# --- install engine -----------------------------------------------------------
install -m 644 -- "$SRC_DIR/we" "$TARGET/we"
install -m 644 -- "$SRC_DIR/funcs.sh" "$TARGET/funcs.sh"
mkdir -p -- "$TARGET/state"
log "installed we + funcs.sh into $TARGET"

# --- migrate legacy profile scripts ------------------------------------------
# v1 profile scripts look like:
#   #!/bin/bash
#   WE_DIR=$HOME/.we
#   weName=<name>
#   cd /some/dir
#   unalias -a
#   source /tmp/we_realias
#   source /home/.../.we/funcs.sh
#   source /home/.../.we/we_<name>_alias
#   ...user lines (cd/echo/source/alias)...
# v2 runs such files after restoring the parent state, so the v1 boilerplate
# (unalias -a / source /tmp/we_realias / funcs / self-alias-source) is removed
# and everything else (user lines) is kept.
migrate_profile() {
    local name=$1 file="$TARGET/we_$1" out
    [ -f "$file" ] || return 0
    # only touch files that still contain v1 boilerplate
    grep -q 'we_realias\|^weName=\|^unalias -a' "$file" || return 0

    out=$(mktemp -- "${file}.migrated.XXXXXX") || return 0
    {
        printf '#!/bin/bash\n'
        printf '# we profile: %s (migrated from v1 by install.sh)\n' "$name"
        printf '# Runs in the %s subshell after the parent shell state has\n' "$name"
        printf '# been inherited. Edit freely.\n'
        sed -E \
            -e '/^#!\/bin\/bash[[:space:]]*$/d' \
            -e '/^WE_DIR=/d' \
            -e '/^weName=/d' \
            -e '/^unalias -a[[:space:]]*$/d' \
            -e '/we_realias/d' \
            -e '/^source [^ ]*\.we[\/]?funcs\.sh[[:space:]]*$/d' \
            -e "/^source [^ ]*we_${name}_alias[[:space:]]*$/d" \
            "$file"
    } > "$out" || { rm -f -- "$out"; return 0; }
    mv -- "$out" "$file"
    log "migrated legacy profile: $name"
}

if [ -d "$TARGET" ]; then
    for f in "$TARGET"/we_*; do
        [ -f "$f" ] || continue
        b=${f##*/}
        b=${b#we_}
        [ "$b" = alias ] && continue
        [ "$b" = func ] && continue
        case $b in *_alias|*_func) continue;; esac
        migrate_profile "$b"
    done
fi

# --- clean legacy entry aliases from the base alias file ----------------------
# v1 persisted entry commands into we_alias like:
#   alias sc='. /home/m/.we/we_sc ; source /home/m/.we/we_sc_alias'
#   alias ai="cat $HOME/.bashrc $WE_DIR/we_ai > /tmp/we_ai_bashrc ; bash --rcfile /tmp/we_ai_bashrc"
# v2 registers entry commands as functions; those lines must go.
base_alias="$TARGET/we_alias"
if [ -f "$base_alias" ]; then
    tmp=$(mktemp -- "${base_alias}.clean.XXXXXX")
    grep -v -E "^alias [A-Za-z0-9._-]+=('|\")\.( |\$)|^alias [A-Za-z0-9._-]+=('|\")cat [^\"]*\.we/we_[A-Za-z0-9._-]+" \
        "$base_alias" > "$tmp" 2>/dev/null || : > "$tmp"
    if ! cmp -s -- "$tmp" "$base_alias"; then
        mv -- "$tmp" "$base_alias"
        log "removed legacy entry aliases from $base_alias"
    else
        rm -f -- "$tmp"
    fi
fi

# --- make sure the shell starts we --------------------------------------------
rcfile=""
for cand in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    if [ -f "$cand" ]; then rcfile=$cand; break; fi
done
if [ -z "$rcfile" ]; then
    warn "no ~/.bashrc / ~/.profile found; add this line to your shell rc manually:"
    warn "  source \"$TARGET/we\""
else
    if grep -q "^\s*source \$HOME/\.we/we\b\|^\s*\. \$HOME/\.we/we\b\|^\s*source \"$TARGET/we\"" "$rcfile" 2>/dev/null; then
        log "$rcfile already sources the we script - left untouched"
    elif grep -q "\.we/we\b" "$rcfile" 2>/dev/null; then
        log "$rcfile references .we/we in a custom line - left untouched, verify it"
    else
        printf '\n# we - work env profile manager\nsource %q\n' "$TARGET/we" >> "$rcfile"
        log "added 'source $TARGET/we' to $rcfile"
    fi
fi

log "done. Open a new shell (or: source $TARGET/we) and try:"
log "  we foo        # create profile foo"
log "  foo           # enter the foo subshell"
log "  we ls         # list profiles"
