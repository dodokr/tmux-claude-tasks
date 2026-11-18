#!/usr/bin/env bash
# Tests for claude-tasks on an isolated tmux server with fake Claude processes. They fire the
# real hook, so this checks how sessions are tied to the process hosting them.
#
#   tests/test.sh

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d)"
conf="$dir/tmux.conf"
sock="claude-tasks-test-$$"
T() { tmux -L "$sock" -f "$conf" "$@"; }
trap 'T kill-server 2>/dev/null || true; rm -rf -- "$dir"' EXIT

failures=0
check() { # description, then a command that must succeed
    local what="$1"
    shift
    if "$@"; then
        echo "ok   $what"
    else
        echo "FAIL $what"
        failures=$((failures + 1))
    fi
}

mkdir "$dir/state" "$dir/bin"
printf 'set -g default-shell /bin/sh\nset -g base-index 1\n' >"$conf"

# A fake Claude: fires SessionStart like Claude Code would (the hook is its child), then idles.
cat >"$dir/bin/fake-claude" <<EOF
#!/bin/sh
printf '{"cwd":"/work","session_id":"%s"}' "\$1" | "$root/claude-tasks" hook SessionStart
exec sleep 300
EOF
# A wrapper that runs it without exec, like a launcher script; tmux then reports the pane's
# command as "sh", the wrapper's interpreter.
cat >"$dir/bin/wrapper" <<EOF
#!/bin/sh
"$dir/bin/fake-claude" "\$@"
EOF
chmod +x "$dir/bin/fake-claude" "$dir/bin/wrapper"

T new-session -d -s base sleep 300
T set-environment -g CLAUDE_TASKS_DIR "$dir/state"
export TMUX="$(T display -p '#{socket_path}'),0,0" CLAUDE_TASKS_DIR="$dir/state"

pane() { T new-window -d -P -F '#{pane_id}' -t base; }
run() { T send-keys -t "$1" "$2" Enter; }
listed() { "$root/claude-tasks" list | cut -f1 | grep -qx -- "$1"; }
not_listed() { ! listed "$1"; }
wait_for() { # file: wait until the hook has written it
    for _ in $(seq 50); do [[ -s "$1" ]] && return 0; sleep 0.1; done
    return 1
}

wrapped=$(pane)
run "$wrapped" "$dir/bin/wrapper s1"
direct=$(pane)
run "$direct" "$dir/bin/fake-claude s2"
wait_for "$dir/state/${wrapped#%}"
wait_for "$dir/state/${direct#%}"

check "the hook records the process hosting the session" \
    grep -qE $'\ts1\t[0-9]+ [0-9]+$' "$dir/state/${wrapped#%}"
check "a session started through a non-exec wrapper is listed" listed "$wrapped"
check "...although tmux reports that pane as running a shell" \
    test "$(T display -p -t "$wrapped" '#{pane_current_command}')" = sh
check "a session started directly is listed" listed "$direct"

pkill -KILL -P "$(T display -p -t "$direct" '#{pane_pid}')"  # Claude dies; no SessionEnd
sleep 0.3
check "a killed session (no SessionEnd) is hidden" not_listed "$direct"
check "...but its state file is kept" test -f "$dir/state/${direct#%}"

run "$direct" "$dir/bin/fake-claude s3"
sleep 1
check "a new session in that pane shows up again" listed "$direct"
check "...with the new session id" grep -q $'\ts3\t' "$dir/state/${direct#%}"

old=$(pane)
printf 'done\t%s\t/work\ts4\n' "$(date +%s)" >"$dir/state/${old#%}"
check "an entry without a recorded process stays listed" listed "$old"

reused=$(pane)
printf 'done\t%s\t/work\ts5\t%s 1\n' "$(date +%s)" "$$" >"$dir/state/${reused#%}"
check "a reused pid (same pid, other start time) is not mistaken for the session" not_listed "$reused"

# Older versions recorded ps's lstart, which shifts by seconds after the machine sleeps.
legacy=$(pane)
printf 'idle\t%s\t/work\ts7\t%s Thu Jan 1 00:00:00 1970\n' "$(date +%s)" "$$" >"$dir/state/${legacy#%}"
check "an entry recorded as ps lstart counts as open while its pid exists" listed "$legacy"
printf 'idle\t%s\t/work\ts7\t999999999 Thu Jan 1 00:00:00 1970\n' "$(date +%s)" >"$dir/state/${legacy#%}"
check "...and as gone once it doesn't" not_listed "$legacy"
T kill-pane -t "$legacy"

host="$(cut -f5 "$dir/state/${wrapped#%}")"
check "the start time recorded is the kernel's (stable across sleep), not ps's lstart" \
    test "$host" = "${host%% *} $(cut -d' ' -f22 "/proc/${host%% *}/stat")"
nproc=$(pane)
printf 'idle\t%s\t/work\ts8\t%s\n' "$(date +%s)" "$(LC_ALL=C ps -o pid=,lstart= -p $$ | tr -s ' ' | sed 's/^ //')" >"$dir/state/${nproc#%}"
check "without /proc, start times come from ps" \
    bash -c "CLAUDE_TASKS_PROC=/nonexistent '$root/claude-tasks' list | cut -f1 | grep -qx -- '$nproc'"
T kill-pane -t "$nproc"

outside=$(pane)
printf '{"cwd":"/work","session_id":"s6"}' | TMUX_PANE="$outside" "$root/claude-tasks" hook SessionStart
check "a hook not running inside its pane records no process" \
    grep -qE $'\ts6\t$' "$dir/state/${outside#%}"
check "...and the entry stays listed" listed "$outside"

T kill-pane -t "$old"
"$root/claude-tasks" list >/dev/null
check "an entry whose pane closed is removed" test ! -f "$dir/state/${old#%}"

# tmux-resurrect: after a save, the open sessions are written next to the save file.
mkdir "$dir/resurrect"
T set -g @resurrect-dir "$dir/resurrect"
touch "$dir/resurrect/tmux_resurrect_1.txt" "$dir/resurrect/tmux_resurrect_0.txt.claude-tasks"
ln -s tmux_resurrect_1.txt "$dir/resurrect/last"
"$root/claude-tasks" resurrect-save
saved="$dir/resurrect/tmux_resurrect_1.txt.claude-tasks"
target() { T display -p -t "$1" '#S:#I.#P'; }
check "resurrect-save lists each open session by session:window.pane" \
    test "$(sort "$saved")" = "$(printf '%s\ts1\t/work\n%s\ts3\t/work\n%s\ts6\t/work\n' \
        "$(target "$wrapped")" "$(target "$direct")" "$(target "$outside")" | sort)"
check "...and drops the lists of deleted saves" test ! -e "$dir/resurrect/tmux_resurrect_0.txt.claude-tasks"

# A restore brings the panes back with a shell; the sessions are resumed into them.
pkill -KILL -P "$(T display -p -t "$wrapped" '#{pane_pid}')"
pkill -KILL -P "$(T display -p -t "$direct" '#{pane_pid}')"
printf 'base:1.0\ts9\t/work\n=nosuch:9.9\tsX\t/work\nbase:1.0\t$(evil)\t/w\n' >>"$saved"
mkdir "$dir/work"
sed -i "s|\ts6\t/work\$|\ts6\t$dir/work|" "$saved"
sleep 0.3
T set -g @claude-tasks-resume-command "echo resumed {id} >$dir/resumed-{id}"
"$root/claude-tasks" resurrect-restore
sleep 0.5
check "resurrect-restore resumes each session in its pane" \
    test -f "$dir/resumed-s1" -a -f "$dir/resumed-s3" -a -f "$dir/resumed-s6"
check "...but not in a pane running something other than a shell" test ! -e "$dir/resumed-s9"
check "...after changing to the session's folder if the pane is elsewhere" \
    test "$(T display -p -t "$outside" '#{pane_current_path}')" = "$dir/work"
T set -g @claude-tasks-restore type
T set -g @claude-tasks-resume-command "echo typed {id}"
"$root/claude-tasks" resurrect-restore
sleep 0.3
check "with @claude-tasks-restore type, the command is typed but not run" \
    bash -c "tmux -L '$sock' capture-pane -p -t '$direct' | grep -q 'typed s3\$'"

echo
((failures == 0)) && echo "all passed" || { echo "$failures failed"; exit 1; }
