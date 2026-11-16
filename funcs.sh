#!/bin/bash
# ============================================================================
# we - funcs.sh : tools available in profile subshells (and in the base shell)
#
#   walias <name> <command...>   create a persisted alias
#   wcd    <name>                alias <name> -> cd to the current directory
#
# Persistence target:
#   inside a profile subshell (WE_PROFILE set) -> $WE_DIR/we_<profile>_alias
#   in the base shell (no WE_PROFILE)          -> $WE_DIR/we_alias
# ============================================================================

# ---------------------------------------------------------------------------
# _we_profile_alias_file
#   echo the alias file to persist into
# ---------------------------------------------------------------------------
_we_profile_alias_file() {
    if [ -n "${WE_PROFILE-}" ]; then
        printf '%s\n' "$WE_DIR/we_${WE_PROFILE}_alias"
    else
        printf '%s\n' "$WE_DIR/we_alias"
    fi
}

# ---------------------------------------------------------------------------
# _we_profile_alias_upsert <name> <value>
#   atomically add/replace `alias <name>='<value>'` in the profile alias file
# ---------------------------------------------------------------------------
_we_profile_alias_upsert() {
    local name=$1 value=$2
    local file tmp pat
    file=$(_we_profile_alias_file)
    [ -n "$file" ] || return 1

    tmp=$(mktemp -- "${file}.tmp.XXXXXX" 2>/dev/null) || return 1

    # remove any old line defining this name, keep the rest
    pat=${name//./\\.}   # escape dots so e.g. 'q.5' cannot match 'q5x'
    if [ -f "$file" ]; then
        grep -v -E "^alias ${pat}=" "$file" > "$tmp" 2>/dev/null || : > "$tmp"
    else
        : > "$tmp"
    fi
    printf "alias %s='%s'\n" "$name" "${value//\'/\'\\\'\'}" >> "$tmp"
    mv -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# walias <name> <command...>
#   create an alias in this shell and persist it for the current profile
#   (or the base alias file when used outside a profile).
#
#   e.g.  walias b /x/.venv/bin/python
#         walias ag 'cd /ai/agentic ; source .venv/bin/activate'
# ---------------------------------------------------------------------------
walias() {
    local name=${1-}
    if [ -z "$name" ] || [ $# -lt 2 ]; then
        printf 'usage: walias <alias name> <alias value>\n'
        printf '\tvalue can be any bash command or multiple commands\n'
        printf '\tenclose multi-word values in quotes\n'
        return 1
    fi
    if [[ $name == *=* ]] || [[ $name == *" "* ]] || [[ $name == -* ]]; then
        printf 'walias: invalid alias name: %s\n' "$name" >&2
        return 1
    fi

    shift
    local value=$*
    local file
    file=$(_we_profile_alias_file)

    # alias builtin: name=value
    if ! alias "$name=$value" 2>/dev/null; then
        printf 'walias: could not create alias: %s\n' "$name" >&2
        return 1
    fi

    if _we_profile_alias_upsert "$name" "$value"; then
        printf '\n\t%s is set to => %s\n\t(persisted in %s)\n\n' "$name" "$value" "$file"
    else
        printf '\n\t%s is set to => %s\n\twarning: could not persist to %s\n\n' "$name" "$value" "$file"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# wcd <name>
#   alias <name> that cd's into the current directory.
#   e.g.  cd /x/y/z && wcd m     ->   alias m='cd /x/y/z'
# ---------------------------------------------------------------------------
wcd() {
    local name=${1-}
    if [ -z "$name" ]; then
        printf 'usage: wcd <short name for this dir>\n'
        return 1
    fi
    if [[ $name == *=* ]] || [[ $name == *" "* ]] || [[ $name == -* ]]; then
        printf 'wcd: invalid name: %s\n' "$name" >&2
        return 1
    fi
    local dir
    dir=$(pwd) || return 1
    # single-quote the path so dirs with spaces survive alias expansion
    local q=${dir//\'/\'\\\'\'}
    walias "$name" "cd '$q'"
    return 0
}

# ---------------------------------------------------------------------------
# _we_name_in_file <name> <file>
#   success if <file> contains an alias line defining <name>
# ---------------------------------------------------------------------------
_we_name_in_file() {
    local wanted=$1 file=$2 line n
    [ -f "$file" ] || return 1
    while IFS= read -r line; do
        n=${line#alias }
        n=${n%%=*}
        [ "$n" = "$wanted" ] && return 0
    done < "$file"
    return 1
}

# ---------------------------------------------------------------------------
# _we_profile_exit_save <profile> <sid>
#   EXIT trap of the profile subshell: persist every alias that exists now
#   but was not present when the profile started (covers plain `alias ...`
#   as well as walias/wcd, which also persist eagerly).
# ---------------------------------------------------------------------------
_we_profile_exit_save() {
    local prof=${1-} sid=${2-}
    local prefile curfile file name line
    [ -n "$prof" ] && [ -n "$sid" ] || return 0

    file="$WE_DIR/we_${prof}_alias"
    prefile="$WE_DIR/state/${sid}.pre"
    curfile="$WE_DIR/state/${sid}.cur"

    alias > "$curfile" 2>/dev/null || return 0
    [ -f "$prefile" ] || return 0

    # names present now but absent at profile start = session-new aliases
    local -A newset=()
    while IFS= read -r line; do
        name=${line#alias }
        name=${name%%=*}
        # skip pathological names that would break associative subscripts
        case $name in *"["*|*"]"*|*"'"*|*'$'*|*"\$"*|*" "*) continue;; esac
        _we_name_in_file "$name" "$prefile" || newset[$name]=1
    done < "$curfile"
    [ ${#newset[@]} -gt 0 ] || return 0

    # rebuild the file: existing definitions (first wins, refreshed from the
    # live shell for changed names) + session-new aliases, nothing else
    local tmp
    tmp=$(mktemp -- "${file}.tmp.XXXXXX" 2>/dev/null) || return 0
    local -A written=()
    if [ -f "$file" ]; then
        while IFS= read -r line; do
            name=${line#alias }
            name=${name%%=*}
            [ -n "$name" ] || continue
            case $name in *"["*|*"]"*|*"'"*|*'$'*|*"\$"*|*" "*) printf '%s\n' "$line" >> "$tmp"; continue;; esac
            [ -n "${written[$name]:-}" ] && continue   # duplicate: keep first
            written[$name]=1
            if [ -n "${newset[$name]:-}" ]; then
                line=$(alias "$name" 2>/dev/null)
                [ -n "$line" ] || continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"
    fi
    while IFS= read -r line; do
        name=${line#alias }
        name=${name%%=*}
        [ -n "${written[$name]:-}" ] && continue
        [ -n "${newset[$name]:-}" ] || continue
        written[$name]=1
        printf '%s\n' "$line" >> "$tmp"
    done < "$curfile"
    mv -- "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp"
    return 0
}

return 0 2>/dev/null || true
