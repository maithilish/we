#!/bin/bash
# ============================================================================
# we - funcs.sh : tools available in profile subshells (and in the base shell)
#
#   walias <name> <command...>   create a persisted alias
#   wcd    <name>                alias <name> -> cd to the current directory
#   wfunc  <name> <body>         define + persist a function
#
# Persistence target:
#   inside a profile subshell (WE_PROFILE set) -> $WE_DIR/we_<profile>_alias / _func
#   in the base shell (no WE_PROFILE)          -> $WE_DIR/we_alias / we_func
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
# _we_danger_check <value>
#   Scan an alias value or function body for dangerous command patterns.
#
#   Two tiers:
#     HARD BLOCK  – catastrophic, no recovery. Refused outright.
#     CONFIRM     – dangerous. Asks for uppercase Y before proceeding.
#
#   Returns:
#     0  safe (or confirmed) – proceed
#     1  refused (hard block or user cancelled) – abort
#
#   Set WE_DANGER_AUTOCONFIRM to skip the interactive prompt:
#     Y  = auto-confirm
#     anything else = auto-cancel
#     (unset = interactive read from stdin)
# ---------------------------------------------------------------------------
_we_danger_check() {
    local value=$1

    # -- helpers ----------------------------------------------------------
    _dc_refuse() {
        printf '\n' >&2
        printf '\e[1;31m  we: REFUSED\e[0m – %s\n' "$1" >&2
        printf '  command : %s\n' "$value" >&2
        printf '  reason  : %s\n' "$2" >&2
        printf '\n' >&2
    }

    _dc_confirm() {
        printf '\n' >&2
        printf '\e[1;33m  we: WARNING\e[0m – %s\n' "$1" >&2
        printf '  command : %s\n' "$value" >&2
        printf '  reason  : %s\n' "$2" >&2
        printf '\n' >&2
        if [ -n "${WE_DANGER_AUTOCONFIRM-}" ]; then
            if [ "$WE_DANGER_AUTOCONFIRM" = "Y" ]; then
                printf '  (auto-confirmed: WE_DANGER_AUTOCONFIRM=Y)\n' >&2
                return 0
            fi
            printf '  (auto-cancelled: WE_DANGER_AUTOCONFIRM=%s)\n' "$WE_DANGER_AUTOCONFIRM" >&2
            return 1
        fi
        printf '  Type Y (uppercase) to confirm, anything else to cancel: ' >&2
        local ans
        IFS= read -r ans
        if [ "$ans" = "Y" ]; then
            return 0
        fi
        printf '  we: cancelled.\n' >&2
        return 1
    }

    # -- HARD BLOCK: catastrophic, refuse ---------------------------------

    # rm targeting /, ~, /*, * or %  (any flag combination)
    #   matches:  rm -rf /   rm -fr ~   rm -r -f *   rm --recursive --force /
    #   skips:    rm -rf /tmp/build   rm file.txt   rm -rf ./build
    if printf '%s' "$value" | grep -qE '\brm\b[[:space:]]+(-+[a-zA-Z-]+[[:space:]]+)*(/|~|~/|/\*|\*|%)([[:space:];|&)]|$)'; then
        _dc_refuse "catastrophic rm target" \
            "rm targeting /, ~, /*, or * permanently deletes the root filesystem, your home directory, or every file in the current directory. There is no trash bin, no undo, no recovery."
        return 1
    fi

    # mkfs (any variant: mkfs.ext4, mkfs.xfs, mkfs.vfat, …)
    if printf '%s' "$value" | grep -qE '\bmkfs(\.[a-zA-Z0-9]+)?\b'; then
        _dc_refuse "mkfs (filesystem format)" \
            "mkfs formats a block device and destroys every byte of data on it. This is irreversible and cannot be undone with any recovery tool."
        return 1
    fi

    # dd writing to a raw block device
    if printf '%s' "$value" | grep -qE '\bdd\b[^|;&]*of=/dev/'; then
        _dc_refuse "dd to raw device" \
            "dd writes raw blocks directly to a device, bypassing the filesystem. Writing to /dev/sd*, /dev/nvme*, etc. destroys all data on the disk."
        return 1
    fi

    # fork bomb
    if printf '%s' "$value" | grep -qE ':\(\)[[:space:]]*\{'; then
        _dc_refuse "fork bomb" \
            "a fork bomb spawns processes exponentially until the system exhausts its process table and becomes unresponsive. Only a hard reboot recovers the system."
        return 1
    fi

    # mv /dev/null (overwrites any file with empty content)
    if printf '%s' "$value" | grep -qE '\bmv\b[[:space:]]+/dev/null\b'; then
        _dc_refuse "mv /dev/null (file overwrite)" \
            "mv /dev/null <file> replaces <file> with an empty file, destroying its contents irreversibly. This affects any file, including /etc/passwd, /etc/shadow, and system binaries."
        return 1
    fi

    # redirect to raw block device
    if printf '%s' "$value" | grep -qE '>[[:space:]]*/dev/(sd[a-z]|nvme|hd[a-z]|xvd[a-z]|mmcblk)'; then
        _dc_refuse "redirect to raw block device" \
            "redirecting output to /dev/sd*, /dev/nvme*, etc. writes raw data to the disk, bypassing the filesystem and destroying all data."
        return 1
    fi

    # find / with -delete (mass deletion from root)
    if printf '%s' "$value" | grep -qE '\bfind\b[[:space:]]+/( |$)[^|;&]*-delete'; then
        _dc_refuse "find / -delete (mass deletion)" \
            "find / -delete removes files from the entire filesystem starting at root. This is catastrophic and irreversible."
        return 1
    fi

    # -- CONFIRM: dangerous, ask for uppercase Y --------------------------

    # rm -r or rm -rf (any target not caught by hard block above)
    if printf '%s' "$value" | grep -qE '\brm\b[[:space:]]+-+[a-zA-Z-]*[rR][a-zA-Z-]*'; then
        if _dc_confirm "recursive rm" \
            "recursive rm (-r / -rf) permanently deletes directories and all their contents. There is no trash bin and no undo. Double-check the target path."; then
            return 0
        fi
        return 1
    fi

    # chmod -R (recursive permission change)
    if printf '%s' "$value" | grep -qE '\bchmod\b[[:space:]]+-R\b'; then
        if _dc_confirm "recursive chmod" \
            "chmod -R changes permissions on every file in a directory tree. Wrong permissions can break system tools, expose sensitive files, or lock you out of your own directories."; then
            return 0
        fi
        return 1
    fi

    # find with -delete (not from /)
    if printf '%s' "$value" | grep -qE '\bfind\b[^|;&]*-delete'; then
        if _dc_confirm "find -delete" \
            "find -delete permanently removes every file matching the expression. There is no trash bin and no undo."; then
            return 0
        fi
        return 1
    fi

    # dd (without of=/dev/, e.g. dd to a regular file)
    if printf '%s' "$value" | grep -qE '\bdd\b'; then
        if _dc_confirm "dd (raw block copy)" \
            "dd performs raw block-level copies. A wrong of= target can destroy data on disks, USB drives, or other block devices."; then
            return 0
        fi
        return 1
    fi

    # system power commands
    if printf '%s' "$value" | grep -qE '\b(shutdown|reboot|halt|poweroff)\b'; then
        if _dc_confirm "system power command" \
            "this command will shut down, halt, or reboot the system. All unsaved work will be lost."; then
            return 0
        fi
        return 1
    fi

    # safe
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

    # danger check: refuse catastrophic values, confirm dangerous ones
    if ! _we_danger_check "$value"; then
        return 1
    fi

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
# _we_profile_func_file
#   echo the function file to persist into
# ---------------------------------------------------------------------------
_we_profile_func_file() {
    if [ -n "${WE_PROFILE-}" ]; then
        printf '%s\n' "$WE_DIR/we_${WE_PROFILE}_func"
    else
        printf '%s\n' "$WE_DIR/we_func"
    fi
}

# ---------------------------------------------------------------------------
# _we_profile_func_upsert <name>
#   atomically add/replace the `declare -f <name>` block in the func file.
#   A block runs from its "name ()" header line to the next line that is
#   exactly "}" (the function body is indented, so only the closing brace of
#   the function itself sits at column 0).
# ---------------------------------------------------------------------------
_we_profile_func_upsert() {
    local name=$1
    local file tmp block line skip=0
    file=$(_we_profile_func_file)
    [ -n "$file" ] || return 1

    block=$(declare -f -- "$name" 2>/dev/null) || return 1
    [ -n "$block" ] || return 1

    tmp=$(mktemp -- "${file}.tmp.XXXXXX" 2>/dev/null) || return 1

    # remove any old block for this name, keep the rest
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$skip" -eq 1 ]; then
                [ "$line" = "}" ] && skip=0
                continue
            fi
            if [[ $line =~ ^${name}\ \(\)[[:space:]]*$ ]]; then
                skip=1
                continue
            fi
            printf '%s\n' "$line"
        done < "$file" > "$tmp"
    else
        : > "$tmp"
    fi
    printf '%s\n' "$block" >> "$tmp"
    printf '\n' >> "$tmp"
    mv -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# wfunc <name> <body>
#   define a function in this shell and persist it for the current profile
#   (or the base function file when used outside a profile).
#
#   e.g.  wfunc hi 'echo "hello $1"'
#         wfunc greet '
#             echo "hi $1"
#             echo "how are you?"
#         '
#
#   The body is the function body (quote it; multi-line is fine). It is
#   defined immediately and persisted in its canonical `declare -f` form, so
#   the stored block is re-source safe.
# ---------------------------------------------------------------------------
wfunc() {
    local name=${1-}
    if [ -z "$name" ] || [ $# -lt 2 ]; then
        printf 'usage: wfunc <name> <body>\n'
        printf '\tbody is the function body; quote it (multi-line ok)\n'
        printf '\te.g. wfunc hi "echo hello"\n'
        return 1
    fi
    if ! [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf 'wfunc: invalid function name: %s\n' "$name" >&2
        printf 'wfunc: names must match [A-Za-z_][A-Za-z0-9_]*\n' >&2
        return 1
    fi

    shift
    local body=$*
    # strip trailing whitespace so the closing "; }" stays on the body's last
    # line (a trailing newline would put the ";" on its own line: a syntax error)
    while [[ $body =~ [[:space:]]$ ]]; do body=${body%?}; done

    # danger check: refuse catastrophic values, confirm dangerous ones
    if ! _we_danger_check "$body"; then
        return 1
    fi

    # define the function in this shell. eval parses the definition; the body
    # is not executed, so $1/$2/... are stored literally for call time.
    if ! eval "$name() { $body; }" 2>/dev/null; then
        printf 'wfunc: could not define function %s (invalid body?)\n' "$name" >&2
        return 1
    fi

    # warn if the name shadows an existing profile entry command (bash gives
    # functions precedence over the profile command, so `name` would call the
    # function instead of entering the profile)
    if [ -f "$WE_DIR/we_$name" ]; then
        printf 'wfunc: note: %s is also a profile name; the function shadows the profile entry command in this shell\n' "$name" >&2
    fi

    local file
    file=$(_we_profile_func_file)
    if _we_profile_func_upsert "$name"; then
        printf '\n\t%s is set to =>\n%s\n\t(persisted in %s)\n\n' "$name" "$(declare -f -- "$name")" "$file"
    else
        printf '\n\t%s is set to =>\n%s\n\twarning: could not persist to %s\n\n' "$name" "$(declare -f -- "$name")" "$file"
    fi
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

# ---------------------------------------------------------------------------
# _we_session_cleanup <profile> <sess_sid>
#   Remove this session's transient files (rcfile + pre/cur baseline). Called
#   from the profile subshell's EXIT trap so every session cleans up after
#   itself -- including the last profile in a switch chain, whose files the
#   original parent we_enter cannot know about. The base snapshot is never
#   touched here.
# ---------------------------------------------------------------------------
_we_session_cleanup() {
    local prof=${1-} sid=${2-}
    [ -n "$prof" ] && [ -n "$sid" ] || return 0
    rm -f -- "$WE_DIR/state/rc_${prof}_${sid}" \
            "$WE_DIR/state/${sid}.pre" \
            "$WE_DIR/state/${sid}.cur" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Shared history (A2): one live $HISTFILE across the base shell, every profile,
# and every terminal. The sync is chained into PROMPT_COMMAND (never clobbering
# an existing one) and runs two builtins per prompt:
#   history -a   append this shell's new lines to $HISTFILE
#   history -n   pull other shells' new lines into this shell's history
# Both are offset-tracked by bash, so repeated calls are cheap no-ops.
# ---------------------------------------------------------------------------
_we_hist_sync() {
    history -a 2>/dev/null
    history -n 2>/dev/null
}

# Idempotently chain _we_hist_sync into PROMPT_COMMAND. Handles both the
# string form and the array form (bash 5.1+). Never clobbers an existing
# PROMPT_COMMAND.
_we_history_install() {
    local d
    d=$(declare -p PROMPT_COMMAND 2>/dev/null)
    if [[ $d == "declare -a"* ]]; then
        # array form (bash 5.1+): append as a new element
        PROMPT_COMMAND+=("_we_hist_sync")
    else
        # string form (or unset)
        case ${PROMPT_COMMAND-} in
            *_we_hist_sync*) : ;;   # already installed
            "") PROMPT_COMMAND="_we_hist_sync" ;;
            *)  PROMPT_COMMAND="$PROMPT_COMMAND; _we_hist_sync" ;;
        esac
    fi
}

return 0 2>/dev/null || true
