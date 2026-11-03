#!/usr/bin/env bash
# Open the picker on an isolated tmux server filled with fake Claude sessions.
# Handy for trying keybindings or taking screenshots without touching real state.
#
#   scripts/demo.sh            attach to the demo (q to quit, then the server is killed)
#   scripts/demo.sh --capture  print the picker as plain text and exit

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d)"
conf="$dir/tmux.conf"
sock=claude-tasks-demo
T() { tmux -L "$sock" -f "$conf" "$@"; }
trap 'T kill-server 2>/dev/null || true; rm -rf -- "$dir"' EXIT

printf 'set -g base-index 1\nset -g pane-base-index 1\n' >"$conf"
mkdir "$dir/state"
now=$(date +%s)

add() { # session title status age-seconds cwd
    local pane
    if T has-session -t "$1" 2>/dev/null; then
        pane=$(T new-window -d -P -F '#{pane_id}' -t "$1" sleep 3600)
    else
        pane=$(T new-session -d -P -F '#{pane_id}' -s "$1" -x 104 -y 14 sleep 3600)
    fi
    T select-pane -t "$pane" -T "✳ $2"
    printf '%s\t%s\t%s\n' "$3" "$((now - $4))" "$5" >"$dir/state/${pane#%}"
}

add webshop "Fix flaky checkout e2e test" waiting 40 ~/code/webshop
add api "Add rate limiting to /login" done 180 ~/code/api
add dotfiles "Migrate nvim config to lazy.nvim" done 3900 ~/dotfiles
add api "Write OpenAPI docs for v2" running 25 ~/code/api
add blog "Draft post on tmux workflows" running 600 ~/notes/blog
add thesis "Summarize related work chapter" idle 90000 ~/school/thesis

T new-session -d -s picker -x 104 -y 11 "CLAUDE_TASKS_DIR=$dir/state $root/claude-tasks"

if [[ "${1:-}" == --capture ]]; then
    sleep 1
    T capture-pane -p ${CAPTURE_ANSI:+-e} -t picker
else
    TMUX='' T attach -t picker
fi
