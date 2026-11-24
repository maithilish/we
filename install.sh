#!/bin/bash
# ============================================================================
# install.sh - install or update the we engine into $HOME/.we
#
# Fresh install (no ~/.we):
#   Creates ~/.we, copies engine files, patches ~/.bashrc.
#
# Update (~/.we exists):
#   Asks for confirmation, backs up, copies engine files, migrates any
#   legacy v1 profiles, patches ~/.bashrc if needed.
#
# Usage: bash install.sh
# ============================================================================
set -u

SRC_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET="$HOME/.we"

log()  { printf 'we: %s\n' "$*"; }
warn() { printf 'we: WARNING: %s\n' "$*" >&2; }
die()  { printf 'we: ERROR: %s\n' "$*" >&2; exit 1; }

# --- sanity checks ----------------------------------------------------------
[ -f "$SRC_DIR/we" ]     || die "cannot find 'we' next to install.sh ($SRC_DIR)"
[ -f "$SRC_DIR/funcs.sh" ] || die "cannot find 'funcs.sh' next to install.sh ($SRC_DIR)"
bash -n "$SRC_DIR/we"     || die "syntax check failed: we"
bash -n "$SRC_DIR/funcs.sh" || die "syntax check failed: funcs.sh"

# --- patch .bashrc ----------------------------------------------------------
patch_bashrc() {
    local rcfile
    rcfile=""
    for cand in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        [ -f "$cand" ] && { rcfile=$cand; break; }
    done

    if [ -z "$rcfile" ]; then
        warn "no ~/.bashrc / ~/.profile found"
        warn "add this line to your shell rc manually:"
        warn "  source \"$TARGET/we\""
        return
    fi

    # already sourced?
    if grep -qE "^\s*(source|\.)[[:space:]]+(\$HOME/\.we/we|\"$TARGET/we\")" "$rcfile" 2>/dev/null; then
        log "$rcfile already sources we - left untouched"
        return
    fi
    # references .we/we in some custom form?
    if grep -q '\.we/we\b' "$rcfile" 2>/dev/null; then
        log "$rcfile references .we/we in a custom line - left untouched, verify it"
        return
    fi

    printf '\n# we - work env profile manager\nsource %q\n' "$TARGET/we" >> "$rcfile"
    log "added 'source $TARGET/we' to $rcfile"
}

# --- migrate legacy v1 profile scripts --------------------------------------
# v1 profile scripts contain boilerplate (unalias -a, source /tmp/we_realias,
# self-sourcing of funcs.sh / _alias) that v2 does not need. Strip it, keep
# the user's own lines (cd, echo, source venv, ...).
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

migrate_all_profiles() {
    local f b
    for f in "$TARGET"/we_*; do
        [ -f "$f" ] || continue
        b=${f##*/}
        b=${b#we_}
        [ "$b" = alias ] && continue
        [ "$b" = func ]  && continue
        case $b in *_alias|*_func) continue;; esac
        migrate_profile "$b"
    done
}

# --- clean legacy entry aliases from we_alias --------------------------------
# v1 persisted entry commands into we_alias like:
#   alias sc='. /home/m/.we/we_sc ; source /home/m/.we/we_sc_alias'
# v2 registers entry commands as functions; those lines must go.
clean_legacy_entry_aliases() {
    local base_alias="$TARGET/we_alias" tmp
    [ -f "$base_alias" ] || return 0
    tmp=$(mktemp -- "${base_alias}.clean.XXXXXX")
    grep -v -E "^alias [A-Za-z0-9._-]+=('|\")\.( |\$)|^alias [A-Za-z0-9._-]+=('|\")cat [^\"]*\.we/we_[A-Za-z0-9._-]+" \
        "$base_alias" > "$tmp" 2>/dev/null || : > "$tmp"
    if ! cmp -s -- "$tmp" "$base_alias"; then
        mv -- "$tmp" "$base_alias"
        log "removed legacy entry aliases from we_alias"
    else
        rm -f -- "$tmp"
    fi
}

# --- install engine files ----------------------------------------------------
install_engine() {
    install -m 644 -- "$SRC_DIR/we"       "$TARGET/we"
    install -m 644 -- "$SRC_DIR/funcs.sh" "$TARGET/funcs.sh"
    mkdir -p -- "$TARGET/state"
    log "installed we + funcs.sh into $TARGET"
}

# ============================================================================
# main
# ============================================================================

if [ ! -d "$TARGET" ]; then
    # ------------------------------------------------------------------
    # FRESH INSTALL
    # ------------------------------------------------------------------
    log "fresh install (no existing $TARGET)"
    mkdir -p -- "$TARGET" || die "cannot create $TARGET"
    install_engine
    patch_bashrc
    log "done. Open a new shell (or: source $TARGET/we) and try:"
    log "  we foo        # create profile foo"
    log "  foo           # enter the foo subshell"
    log "  we ls         # list profiles"

else
    # ------------------------------------------------------------------
    # UPDATE EXISTING INSTALL
    # ------------------------------------------------------------------
    log "existing installation found at $TARGET"

    # show what's there
    prof_count=$(find "$TARGET" -maxdepth 1 -name 'we_*' \
        ! -name '*_alias' ! -name '*_func' ! -name 'we_alias' ! -name 'we_func' \
        -type f 2>/dev/null | wc -l)
    log "  profiles: $prof_count"
    log "  current version: $(grep -m1 'WE_VERSION=' "$TARGET/we" 2>/dev/null | cut -d= -f2 || echo 'unknown (v1?)')"
    log "  new version:     $(grep -m1 'WE_VERSION=' "$SRC_DIR/we" 2>/dev/null | cut -d= -f2)"

    printf '\n'
    printf 'This will back up %s and replace the engine files (we, funcs.sh).\n' "$TARGET"
    printf 'Your profile data (we_<name>, we_<name>_alias, we_<name>_func) is preserved.\n'
    printf 'Proceed? [y/N] '
    read -r answer
    case $answer in
        [yY]|[yY][eE][sS]) ;;
        *) log "aborted"; exit 0;;
    esac

    # backup
    BACKUP="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$TARGET" "$BACKUP" || die "backup to $BACKUP failed"
    log "backup: $BACKUP"

    install_engine
    migrate_all_profiles
    clean_legacy_entry_aliases
    patch_bashrc
    log "done. Open a new shell (or: source $TARGET/we)"
fi

