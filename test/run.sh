#!/bin/bash
# ============================================================================
# we - regression test harness (Phase 0 baseline)
#
# Runs the we engine against a throwaway sandbox WE_DIR under /tmp and checks
# the full v2 behaviour: create, entry, inheritance, walias/wcd, plain-alias
# persistence, re-entry, management, name validation, spaces-in-paths, the
# extglob-function parse regression, and state/ cleanup.
#
# Usage:
#   bash test/run.sh                 # sandbox under /tmp/we_sandbox
#   WE_TEST_SANDBOX=/tmp/other bash test/run.sh
#
# Exit code 0 = all green, 1 = at least one failure.
# ============================================================================
set -u
# the harness embeds an extglob pattern (T4); parse it like a real shell does
shopt -s extglob 2>/dev/null || true
# start from a clean base: drop any lineage markers inherited from the
# surrounding environment so the "base shell" subshells are truly base
unset WE_ROOT_SID WE_SESSION_SID WE_PROFILE 2>/dev/null || true

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SANDBOX=${WE_TEST_SANDBOX:-/tmp/we_sandbox}
CAPTURE="$SANDBOX/capture.txt"
EV="$SANDBOX/evidence.txt"

PASS=0; FAIL=0

# --- helpers -----------------------------------------------------------------
ok() { # $1 description, $2 condition (evaluated)
    if eval "$2"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"
    fi
}

section() { printf '\n== %s ==\n' "$1"; }

# fresh sandbox with the engine installed from the repo
setup_sandbox() {
    rm -rf -- "$SANDBOX"
    mkdir -p -- "$SANDBOX/.we" "$SANDBOX/x/y/z" "$SANDBOX/dir with space"
    install -m 644 -- "$REPO/we"       "$SANDBOX/.we/we"
    install -m 644 -- "$REPO/funcs.sh" "$SANDBOX/.we/funcs.sh"
}

# Enter a profile: create it (if needed) in a parent shell rooted at $SANDBOX,
# then run the profile. The child reads its commands from $1 (a file) and its
# output goes to $CAPTURE. The parent is a fresh non-interactive bash, so the
# child takes the forced-interactive (--rcfile -i) path.
enter() { # $1 profile name, $2 inner-script file
    (
        cd -- "$SANDBOX" || exit 99
        export WE_DIR="$SANDBOX/.we"
        # shellcheck disable=SC1091
        . "$WE_DIR/we"
        shopt -s expand_aliases
        we "$1" >/dev/null 2>&1
        "$1"
    ) < "$2" > "$CAPTURE" 2>&1
}

# run a snippet in a fresh parent shell rooted at $SANDBOX (no profile entry)
parent_shell() { # $1 snippet file
    (
        cd -- "$SANDBOX" || exit 99
        export WE_DIR="$SANDBOX/.we"
        # shellcheck disable=SC1091
        . "$WE_DIR/we"
        shopt -s expand_aliases
        . "$1"
    ) > "$CAPTURE" 2>&1
}

# strip ANSI/OSC noise from the capture for grepping
clean() { sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\a]*\a//g' "$CAPTURE"; }

# ============================================================================
section "setup"
setup_sandbox
ok "sandbox we installed"      '[ -f "$SANDBOX/.we/we" ]'
ok "sandbox funcs.sh installed" '[ -f "$SANDBOX/.we/funcs.sh" ]'

# --- T1: create + management -------------------------------------------------
section "T1 create / management"
cat > "$SANDBOX/t1.sh" <<'EOF'
we foo >/dev/null
echo "foo_type=$(type -t foo)"
we ls | grep -q foo && echo "ls_has_foo"
we show foo | grep -q "we profile: foo" && echo "show_ok"
we 'bad name' 2>/dev/null; [ ! -f "$WE_DIR/we_bad name" ] && echo "reject_space"
we cd 2>/dev/null;        [ ! -f "$WE_DIR/we_cd" ] && echo "reject_builtin"
we alias 2>/dev/null;     [ ! -f "$WE_DIR/we_alias.bak" ] && echo "reject_alias"
we we 2>/dev/null;        [ ! -f "$WE_DIR/we_we" ] && echo "reject_we"
EOF
parent_shell "$SANDBOX/t1.sh"
ok "foo registered as function" 'clean | grep -q "foo_type=function"'
ok "we ls lists foo"            'clean | grep -q ls_has_foo'
ok "we show works"              'clean | grep -q show_ok'
ok "rejects name with space"    'clean | grep -q reject_space'
ok "rejects builtin name (cd)"  'clean | grep -q reject_builtin'
ok "rejects name alias"         'clean | grep -q reject_alias'
ok "rejects name we"            'clean | grep -q reject_we'
ok "we_foo file created"        '[ -f "$SANDBOX/.we/we_foo" ]'
ok "we_foo_alias file created"  '[ -f "$SANDBOX/.we/we_foo_alias" ]'

# --- T2: entry, inheritance, walias/wcd, plain alias, persistence ------------
section "T2 entry / inheritance / persistence"
# parent state to inherit: a local var, a function, a base alias
cat > "$SANDBOX/t2_inner.sh" <<'EOF'
echo "inher_var=[$myvar]"
echo "inher_func=$(type -t myfunc)"
myfunc
echo "inher_alias=$(type -t baseal)"
walias b /x/.venv/bin/python
wcd m
cd "$SANDBOX/x/y/z"
wcd deep
alias tmp1='echo tmp'
echo "child_b=$(type -t b)"
echo "child_m=$(type -t m)"
EOF
# seed parent state by wrapping: create profile + define state, then enter
cat > "$SANDBOX/t2_driver.sh" <<'EOF'
myvar=hello
myfunc() { echo "myfunc-ran"; }
alias baseal='echo baseal'
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    . "$SANDBOX/t2_driver.sh"
    we foo2 >/dev/null 2>&1
    foo2
) < "$SANDBOX/t2_inner.sh" > "$CAPTURE" 2>&1

ok "inherited local var"        'clean | grep -q "inher_var=\[hello\]"'
ok "inherited function"         'clean | grep -q "inher_func=function"'
ok "inherited function runs"    'clean | grep -q myfunc-ran'
ok "inherited base alias"       'clean | grep -q "inher_alias=alias"'
ok "walias b persisted"         "grep -q \"^alias b='/x/\\.venv/bin/python'\" '$SANDBOX/.we/we_foo2_alias'"
ok "wcd m persisted"            "grep -q \"^alias m='cd\" '$SANDBOX/.we/we_foo2_alias'"
ok "wcd deep persisted"         "grep -q \"^alias deep='cd\" '$SANDBOX/.we/we_foo2_alias'"
ok "plain alias persisted on exit" "grep -q \"^alias tmp1='echo tmp'\" '$SANDBOX/.we/we_foo2_alias'"
ok "no duplicate b lines"       "[ \$(grep -c '^alias b=' '$SANDBOX/.we/we_foo2_alias') = 1 ]"
ok "base alias file untouched"  '[ ! -s "$SANDBOX/.we/we_alias" ]'
ok "child saw b alias"          'clean | grep -q "child_b=alias"'
ok "child saw m alias"          'clean | grep -q "child_m=alias"'

# --- T3: re-entry restores persisted aliases ---------------------------------
section "T3 re-entry"
cat > "$SANDBOX/t3_inner.sh" <<'EOF'
echo "re_b=$(type -t b)"
echo "re_m=$(type -t m)"
echo "re_deep=$(type -t deep)"
echo "re_tmp1=$(type -t tmp1)"
m; echo "m_pwd=$PWD"
deep; echo "deep_pwd=$PWD"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    foo2
) < "$SANDBOX/t3_inner.sh" > "$CAPTURE" 2>&1
ok "reentry b present"    'clean | grep -q "re_b=alias"'
ok "reentry m present"    'clean | grep -q "re_m=alias"'
ok "reentry deep present" 'clean | grep -q "re_deep=alias"'
ok "reentry tmp1 present" 'clean | grep -q "re_tmp1=alias"'
ok "m cd works"           "clean | grep -q \"m_pwd=$SANDBOX\$\""
ok "deep cd works"        "clean | grep -q \"deep_pwd=$SANDBOX/x/y/z\$\""

# --- T4: extglob function parse regression -----------------------------------
section "T4 extglob function parse"
# parent has extglob on (like a real shell with bash-completion) and defines a
# function containing an extglob pattern. The child must parse it without a
# syntax error and the function must run.
cat > "$SANDBOX/t4_inner.sh" <<'EOF'
echo "eg_func=$(type -t _eg_test)"
_eg_test ".."
_eg_test "keep"
echo "eg_extglob=$(shopt -p extglob 2>&1)"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    shopt -s extglob
    _eg_test() { case $1 in ..?(/*)) echo "eg-stripped";; *) echo "eg-keep:$1";; esac; }
    we foo4 >/dev/null 2>&1
    foo4
) < "$SANDBOX/t4_inner.sh" > "$CAPTURE" 2>&1
ok "extglob func parsed (no syntax error)" '! clean | grep -q "syntax error"'
ok "extglob func is a function"             'clean | grep -q "eg_func=function"'
ok "extglob func runs (pattern branch)"     'clean | grep -q "eg-stripped"'
ok "extglob func runs (default branch)"     'clean | grep -q "eg-keep:keep"'

# --- T5: spaces in paths ------------------------------------------------------
section "T5 spaces in paths"
cat > "$SANDBOX/t5_inner.sh" <<'EOF'
cd "$SANDBOX/dir with space"
wcd sp
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    we foo5 >/dev/null 2>&1
    foo5
) < "$SANDBOX/t5_inner.sh" > "$CAPTURE" 2>&1
ok "wcd with spaces persisted" "grep -q \"^alias sp='cd\" '$SANDBOX/.we/we_foo5_alias'"
ok "wcd spaces value correct"  "grep -qF \"dir with space\" '$SANDBOX/.we/we_foo5_alias'"

# --- T6: state/ cleanup after exit -------------------------------------------
# Phase 1+: root snapshots persist after exit (kept for re-entry / Phase 2
# switching); per-session files (rc, pre, cur) must be gone.
section "T6 state cleanup"
ok "no session rc files left"      '[ -z "$(ls "$SANDBOX/.we/state"/rc_* 2>/dev/null)" ]'
ok "no session pre/cur files left" '[ -z "$(ls "$SANDBOX/.we/state"/*.pre "$SANDBOX/.we/state"/*.cur 2>/dev/null)" ]'
ok "only root_* files remain"      '[ -z "$(ls -A "$SANDBOX/.we/state" 2>/dev/null | grep -v "^root_")" ]'

# --- T7: we del ---------------------------------------------------------------
section "T7 delete"
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    echo y | we del foo2 >/dev/null 2>&1
    echo "del_files=$([ -f "$WE_DIR/we_foo2" ] || [ -f "$WE_DIR/we_foo2_alias" ] && echo present || echo gone)"
    echo "del_func=$(type -t foo2)"
) > "$CAPTURE" 2>&1
ok "we del removes files"     'clean | grep -q "del_files=gone"'
ok "we del unregisters func"  'clean | grep -q "del_func=" '

# --- T8: profile-to-profile switching (replace / exec) -----------------------
# Entering a profile from inside another profile must restore the BASE state
# (not the intermediate profile's), persist the outgoing profile first, and
# start in the base directory.
section "T8 switch"
cat > "$SANDBOX/t8_inner.sh" <<'EOF'
# --- running in swf (switch-from) ---
echo "swf_baseal=$(type -t baseal)"
echo "swf_basevar=[$basevar]"
walias swfonly 'echo swfonly'
cd "$SANDBOX/x/y/z"
echo "swf_pwd=$PWD"
swt
# --- running in swt (switch-to, after exec) ---
echo "swt_baseal=$(type -t baseal)"
echo "swt_basevar=[$basevar]"
echo "swt_swfonly=$(type -t swfonly)"
echo "swt_pwd=$PWD"
walias swtonly 'echo swtonly'
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    basevar=basehello
    alias baseal='echo baseal'
    we swf >/dev/null 2>&1
    we swt >/dev/null 2>&1
    swf
) < "$SANDBOX/t8_inner.sh" > "$CAPTURE" 2>&1

ok "swf inherited base alias"      'clean | grep -q "swf_baseal=alias"'
ok "swf inherited base var"        'clean | grep -q "swf_basevar=\[basehello\]"'
ok "swf cd worked"                 "clean | grep -q \"swf_pwd=$SANDBOX/x/y/z\$\""
ok "swt inherited base alias"      'clean | grep -q "swt_baseal=alias"'
ok "swt inherited base var"        'clean | grep -q "swt_basevar=\[basehello\]"'
ok "swt did NOT inherit swf alias" 'clean | grep -q "swt_swfonly=$"'
ok "swt restored base dir"         "clean | grep -q \"swt_pwd=$SANDBOX\$\""
ok "swf alias persisted pre-switch" "grep -q \"^alias swfonly='echo swfonly'\" '$SANDBOX/.we/we_swf_alias'"
ok "swt alias persisted"           "grep -q \"^alias swtonly='echo swtonly'\" '$SANDBOX/.we/we_swt_alias'"
ok "swt file has no swfonly"       "! grep -q swfonly '$SANDBOX/.we/we_swt_alias'"
ok "state clean after switch"      "[ -z \"$(ls -A '$SANDBOX/.we/state' 2>/dev/null | grep -v '^root_')\" ]"

# ============================================================================
printf '\n========================================\n'
printf 'TOTAL: pass=%d fail=%d\n' "$PASS" "$FAIL"
printf '========================================\n'
[ "$FAIL" -eq 0 ]
