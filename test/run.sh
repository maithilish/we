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
ok "state clean after switch"      '[ -z "$(ls -A "$SANDBOX/.we/state" 2>/dev/null | grep -v "^root_")" ]'

# --- T9: root snapshot cleanup on base-shell exit ---------------------------
# The base shell's EXIT trap removes its root_* files, so the state dir is
# empty once the base shell (here: the test subshell) has exited.
section "T9 root cleanup on base exit"
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    we rcprof >/dev/null 2>&1
    rcprof
) < /dev/null > "$CAPTURE" 2>&1
ok "state empty after base exit" '[ -z "$(ls -A "$SANDBOX/.we/state" 2>/dev/null)" ]'

# --- T10: same-profile switch (foo -> foo) ----------------------------------
# Switching to the profile you are already in gives a fresh session with base
# state and the profile's persisted aliases -- no alias doubling.
section "T10 same-profile switch"
cat > "$SANDBOX/t10_inner.sh" <<'EOF'
walias keepme 'echo keepme'
echo "s1_keepme=$(type -t keepme)"
foo10
echo "s2_keepme=$(type -t keepme)"
echo "s2_baseal=$(type -t baseal)"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    alias baseal='echo baseal'
    we foo10 >/dev/null 2>&1
    foo10
) < "$SANDBOX/t10_inner.sh" > "$CAPTURE" 2>&1
ok "s1 has keepme"             'clean | grep -q "s1_keepme=alias"'
ok "s2 has keepme (persisted)" 'clean | grep -q "s2_keepme=alias"'
ok "s2 has base alias"         'clean | grep -q "s2_baseal=alias"'
ok "no alias doubling"         '[ "$(grep -c "^alias keepme=" "$SANDBOX/.we/we_foo10_alias")" = 1 ]'

# --- T11: root snapshot deleted -> switch refused ---------------------------
# With the base snapshot gone, a switch is refused and the user stays in the
# current profile (no exec).
section "T11 root snapshot deleted"
cat > "$SANDBOX/t11_inner.sh" <<'EOF'
rm -f "$WE_DIR"/state/root_*.vars "$WE_DIR"/state/root_*.funcs \
      "$WE_DIR"/state/root_*.aliases "$WE_DIR"/state/root_*.shopt "$WE_DIR"/state/root_*.cwd
bar11
echo "still_in=$WE_PROFILE"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    we foo11 >/dev/null 2>&1
    we bar11 >/dev/null 2>&1
    foo11
) < "$SANDBOX/t11_inner.sh" > "$CAPTURE" 2>&1
ok "switch refused (no root)"  'clean | grep -q "cannot switch to bar11"'
ok "stayed in foo11"           'clean | grep -q "still_in=foo11"'

# --- T12: profile creation inside a profile ---------------------------------
# Creating a profile from inside another profile works, but the entry command
# is only registered in this shell, so a warning is shown.
section "T12 create inside profile"
cat > "$SANDBOX/t12_inner.sh" <<'EOF'
we bar12
echo "bar12_func=$(type -t bar12)"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    we foo12 >/dev/null 2>&1
    foo12
) < "$SANDBOX/t12_inner.sh" > "$CAPTURE" 2>&1
ok "bar12 files created"       '[ -f "$SANDBOX/.we/we_bar12" ]'
ok "bar12 func registered here" 'clean | grep -q "bar12_func=function"'
ok "warning shown"             'clean | grep -q "only available in this shell"'

# --- T13: long switch chain (generation counter) ----------------------------
# Each switch bumps the generation so session files stay unique; the chain
# ends with a clean state dir.
section "T13 long switch chain"
cat > "$SANDBOX/t13_inner.sh" <<'EOF'
echo "gen_a=$WE_SESSION_GEN"
b13
echo "gen_b=$WE_SESSION_GEN"
c13
echo "gen_c=$WE_SESSION_GEN"
d13
echo "gen_d=$WE_SESSION_GEN"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    we a13 >/dev/null 2>&1; we b13 >/dev/null 2>&1
    we c13 >/dev/null 2>&1; we d13 >/dev/null 2>&1
    a13
) < "$SANDBOX/t13_inner.sh" > "$CAPTURE" 2>&1
ok "gen a=1"                   'clean | grep -q "gen_a=1"'
ok "gen b=2"                   'clean | grep -q "gen_b=2"'
ok "gen c=3"                   'clean | grep -q "gen_c=3"'
ok "gen d=4"                   'clean | grep -q "gen_d=4"'
ok "state clean after chain"   '[ -z "$(ls -A "$SANDBOX/.we/state" 2>/dev/null | grep -v "^root_")" ]'

# --- T14: refuse to delete the current profile ------------------------------
section "T14 del current profile guard"
cat > "$SANDBOX/t14_inner.sh" <<'EOF'
we del foo14
echo "foo14_file=$([ -f "$WE_DIR/we_foo14" ] && echo present || echo gone)"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    we foo14 >/dev/null 2>&1
    foo14
) < "$SANDBOX/t14_inner.sh" > "$CAPTURE" 2>&1
ok "del refused (current)"     'clean | grep -q "cannot delete foo14"'
ok "foo14 file still present"  'clean | grep -q "foo14_file=present"'

# --- T15: universal base walias (A0) ----------------------------------------
# A base `walias` is universal: inherited by every profile, survives a
# profile-to-profile switch, is persisted to the base alias file (we_alias),
# and is NOT duplicated into any profile's own alias file.
section "T15 universal base walias"
cat > "$SANDBOX/t15_inner.sh" <<'EOF'
# --- in foo15 ---
echo "f15_n=$(type -t n)"
bar15
# --- in bar15 (after switch) ---
echo "b15_n=$(type -t n)"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    walias n nano >/dev/null
    we foo15 >/dev/null 2>&1
    we bar15 >/dev/null 2>&1
    foo15
) < "$SANDBOX/t15_inner.sh" > "$CAPTURE" 2>&1
ok "foo15 inherited base walias"  'clean | grep -q "f15_n=alias"'
ok "bar15 inherited base walias"  'clean | grep -q "b15_n=alias"'
ok "persisted to base we_alias"   "grep -q \"^alias n='nano'\" '$SANDBOX/.we/we_alias'"
ok "not duplicated into foo15"    '! grep -q "^alias n=" "$SANDBOX/.we/we_foo15_alias"'
ok "not duplicated into bar15"    '! grep -q "^alias n=" "$SANDBOX/.we/we_bar15_alias"'

# --- T16: base alias change seen on re-entry (A0) ---------------------------
# The root snapshot is re-taken on every first entry from the base, so a base
# alias changed between two entries is seen at its new value on re-entry.
section "T16 base alias change on re-entry"
cat > "$SANDBOX/t16_in1.sh" <<'EOF'
[ "$(alias n 2>/dev/null)" = "alias n='nano'" ] && echo "r1=nano" || echo "r1=OTHER"
EOF
cat > "$SANDBOX/t16_in2.sh" <<'EOF'
[ "$(alias n 2>/dev/null)" = "alias n='vim'" ] && echo "r2=vim" || echo "r2=OTHER"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    walias n nano >/dev/null
    we reprof >/dev/null 2>&1
    reprof < "$SANDBOX/t16_in1.sh"
    walias n vim >/dev/null
    reprof < "$SANDBOX/t16_in2.sh"
) > "$CAPTURE" 2>&1
ok "first entry sees nano" 'clean | grep -q "r1=nano"'
ok "second entry sees vim" 'clean | grep -q "r2=vim"'

# --- T17: profile override of a base alias (A0, lock current behaviour) -----
# A profile may shadow a base alias. Persistence depends on the method:
#   - `walias` in the profile persists the shadow (per-profile; wins on re-entry)
#   - plain `alias` in the profile is session-only (base value restored on re-entry)
# This locks the current behaviour so it is not changed accidentally.
section "T17 profile override of base alias"
cat > "$SANDBOX/t17_w1.sh" <<'EOF'
walias ov 'echo profile-ov' >/dev/null
[ "$(alias ov 2>/dev/null)" = "alias ov='echo profile-ov'" ] && echo "w1=profile" || echo "w1=OTHER"
EOF
cat > "$SANDBOX/t17_w2.sh" <<'EOF'
[ "$(alias ov 2>/dev/null)" = "alias ov='echo profile-ov'" ] && echo "w2=profile" || echo "w2=OTHER"
EOF
cat > "$SANDBOX/t17_a1.sh" <<'EOF'
alias ov2='echo profile-ov2'
[ "$(alias ov2 2>/dev/null)" = "alias ov2='echo profile-ov2'" ] && echo "a1=profile" || echo "a1=OTHER"
EOF
cat > "$SANDBOX/t17_a2.sh" <<'EOF'
[ "$(alias ov2 2>/dev/null)" = "alias ov2='echo base-ov2'" ] && echo "a2=base" || echo "a2=OTHER"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    walias ov 'echo base-ov' >/dev/null
    walias ov2 'echo base-ov2' >/dev/null
    we ovprof >/dev/null 2>&1
    ovprof < "$SANDBOX/t17_w1.sh"
    ovprof < "$SANDBOX/t17_w2.sh"
    ovprof < "$SANDBOX/t17_a1.sh"
    ovprof < "$SANDBOX/t17_a2.sh"
) > "$CAPTURE" 2>&1
ok "walias shadow active in session"   'clean | grep -q "w1=profile"'
ok "walias shadow persists (re-entry)" 'clean | grep -q "w2=profile"'
ok "walias shadow in profile file"     "grep -q \"^alias ov='echo profile-ov'\" '$SANDBOX/.we/we_ovprof_alias'"
ok "plain alias shadow active in session" 'clean | grep -q "a1=profile"'
ok "plain alias shadow NOT persisted"    'clean | grep -q "a2=base"'
ok "plain alias shadow not in file"      '! grep -q "profile-ov2" "$SANDBOX/.we/we_ovprof_alias"'

# --- T18: wfunc in a profile (A1) -------------------------------------------
# wfunc defines a function in the session and persists it to we_<prof>_func;
# it survives re-entry; redefining upserts (replaces the old block).
section "T18 wfunc in a profile"
cat > "$SANDBOX/t18_in1.sh" <<'EOF'
wfunc greet 'echo "hello $1"' >/dev/null
echo "r1=$(greet world)"
EOF
cat > "$SANDBOX/t18_in2.sh" <<'EOF'
echo "r2=$(greet again)"
EOF
cat > "$SANDBOX/t18_in3.sh" <<'EOF'
wfunc greet 'echo "hi $1 (v2)"' >/dev/null
echo "r3=$(greet upsert)"
EOF
enter f18 "$SANDBOX/t18_in1.sh"
ok "wfunc defined in session"  'clean | grep -q "r1=hello world"'
enter f18 "$SANDBOX/t18_in2.sh"
ok "wfunc persists (re-entry)" 'clean | grep -q "r2=hello again"'
enter f18 "$SANDBOX/t18_in3.sh"
ok "wfunc upsert (re-entry)"   'clean | grep -q "r3=hi upsert (v2)"'
ok "wfunc in profile file"     "grep -q 'greet ()' '$SANDBOX/.we/we_f18_func'"
ok "upsert replaced old block" "! grep -q 'hello' '$SANDBOX/.we/we_f18_func'"

# --- T19: base wfunc (A1) ----------------------------------------------------
# A base wfunc is universal: inherited by every profile, survives a switch,
# persisted to we_func, and NOT duplicated into any profile's func file.
section "T19 base wfunc"
cat > "$SANDBOX/t19_in.sh" <<'EOF'
echo "f19=$(basefn)"
bar19
echo "b19=$(basefn)"
EOF
(
    cd -- "$SANDBOX" || exit 99
    export WE_DIR="$SANDBOX/.we"
    . "$WE_DIR/we"
    shopt -s expand_aliases
    wfunc basefn 'echo BASE-FUNC' >/dev/null
    we foo19 >/dev/null 2>&1
    we bar19 >/dev/null 2>&1
    foo19
) < "$SANDBOX/t19_in.sh" > "$CAPTURE" 2>&1
ok "foo19 inherited base wfunc"  'clean | grep -q "f19=BASE-FUNC"'
ok "bar19 inherited base wfunc"  'clean | grep -q "b19=BASE-FUNC"'
ok "persisted to base we_func"   "grep -q 'basefn ()' '$SANDBOX/.we/we_func'"
ok "not duplicated into foo19"   "! grep -q 'basefn' '$SANDBOX/.we/we_foo19_func'"
ok "not duplicated into bar19"   "! grep -q 'basefn' '$SANDBOX/.we/we_bar19_func'"
# a fresh base shell (new session) re-sources we_func, so the base func is
# still available without re-defining it
cat > "$SANDBOX/t19_base.sh" <<'EOF'
echo "base19=$(basefn)"
EOF
parent_shell "$SANDBOX/t19_base.sh"
ok "base wfunc persists across sessions" 'clean | grep -q "base19=BASE-FUNC"'

# --- T20: per-profile isolation + multi-line body (A1) -----------------------
# A profile's wfunc is isolated to that profile (not visible in another);
# multi-line bodies are supported and re-source correctly.
section "T20 per-profile isolation + multi-line"
cat > "$SANDBOX/t20_in1.sh" <<'EOF'
wfunc onlyp1 'echo "p1-only $1"' >/dev/null
wfunc multi '
echo "line1 $1"
echo "line2"
' >/dev/null
echo "p1_only=$(onlyp1 x)"
multi m
EOF
cat > "$SANDBOX/t20_in2.sh" <<'EOF'
echo "p2_only=$(onlyp1 2>&1 | head -1)"
EOF
cat > "$SANDBOX/t20_in3.sh" <<'EOF'
multi m
EOF
enter f20a "$SANDBOX/t20_in1.sh"
ok "p1 has its own func"      'clean | grep -q "p1_only=p1-only x"'
ok "multi-line body line1"    'clean | grep -q "line1 m"'
ok "multi-line body line2"    'clean | grep -q "line2"'
enter f20a "$SANDBOX/t20_in3.sh"
ok "multi-line persists (re-entry)" 'clean | grep -q "line1 m"'
enter f20b "$SANDBOX/t20_in2.sh"
ok "p2 does NOT have p1's func" 'clean | grep -q "p2_only=onlyp1: command not found"'
ok "p1 func in f20a file"     "grep -q 'onlyp1 ()' '$SANDBOX/.we/we_f20a_func'"
ok "p1 func NOT in f20b file" "! grep -q 'onlyp1' '$SANDBOX/.we/we_f20b_func'"

# --- T21: wfunc name validation + profile collision (A1) ---------------------
# wfunc rejects names that are not valid shell identifiers, and warns when the
# name matches an existing profile (the function would shadow the entry cmd).
section "T21 wfunc name validation + collision"
# write results to a file (not the capture): the interactive shell echoes the
# command line, which would contain the markers and make grep vacuous
cat > "$SANDBOX/t21_in.sh" <<'EOF'
{
wfunc 'bad-name' 'echo x' 2>&1 | grep -q 'invalid' && echo "v1=invalid" || echo "v1=OTHER"
wfunc '9bad' 'echo x' 2>&1 | grep -q 'invalid' && echo "v2=invalid" || echo "v2=OTHER"
wfunc ok_name 'echo x' >/dev/null
echo "v3=$(type -t ok_name)"
wfunc f21 'echo shadow' 2>&1 | grep -q 'shadows' && echo "v4=warn" || echo "v4=OTHER"
} > t21_out.txt 2>&1
EOF
enter f21 "$SANDBOX/t21_in.sh"
ok "rejects bad-name"          'grep -q "v1=invalid" "$SANDBOX/t21_out.txt"'
ok "rejects 9bad"              'grep -q "v2=invalid" "$SANDBOX/t21_out.txt"'
ok "accepts ok_name"           'grep -q "v3=function" "$SANDBOX/t21_out.txt"'
ok "warns on profile collision" 'grep -q "v4=warn" "$SANDBOX/t21_out.txt"'

# --- T22: profile listing excludes func files (A1) ---------------------------
# we_func (base) and we_<prof>_func (profile) must NOT be listed as profiles
# by `we ls` / _we_profiles (only we_<name> setup files are profiles).
section "T22 profile listing excludes func files"
# write `we ls` to a file (not the capture): the interactive shell echoes the
# command line, which would contain the test markers and make grep vacuous
cat > "$SANDBOX/t22_in.sh" <<'EOF'
we ls > t22_ls.txt 2>&1
EOF
enter f22a "$SANDBOX/t22_in.sh"
ok "we ls does not list func"       '! grep -q "  func " "$SANDBOX/t22_ls.txt"'
ok "we ls does not list f22a_func"  '! grep -q "  f22a_func " "$SANDBOX/t22_ls.txt"'
ok "we ls lists f22a"               'grep -q "  f22a " "$SANDBOX/t22_ls.txt"'

# ============================================================================
printf '\n========================================\n'
printf 'TOTAL: pass=%d fail=%d\n' "$PASS" "$FAIL"
printf '========================================\n'
[ "$FAIL" -eq 0 ]
