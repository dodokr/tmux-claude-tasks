# tmux-claude-tasks

A quiet status board for [Claude Code](https://claude.com/claude-code) sessions running in tmux.

Running several Claude sessions at once means constantly checking which one finished or is
stuck on a permission prompt. Desktop notifications answer that, but they break focus.
`claude-tasks` does the opposite: Claude Code hooks silently record each session's status, and
you look at it only when *you* want to — in a tmux popup with vim keys, from which you jump
straight to the pane.

![claude-tasks picker](docs/screenshot.svg)

*(Screenshot rendered from `scripts/demo.sh`, which uses made-up sessions.)*

## Features

- **Every Claude session in one list**, across all tmux sessions and windows.
- **Status at a glance**, sorted by what needs you first:
  `? waiting` (permission prompt or question) → `● done` → `◐ running` → `○ idle`.
- **Readable topics** — uses the summary Claude Code puts in the pane title
  (e.g. "Fix flaky checkout e2e test"), falling back to the project folder.
- **Vim keys**, Enter to jump to the pane (switching tmux session/window as needed).
- **No notifications, no daemon.** One bash script; each hook call takes ~20 ms.
- Closed panes disappear automatically.

## Requirements

- tmux ≥ 3.3 (`display-popup`)
- A recent [fzf](https://github.com/junegunn/fzf) (uses `--no-input` and `--gutter`; tested with 0.74)
- bash, [jq](https://jqlang.org/)
- Claude Code with hooks support

## Install

1. **Put the script on your `PATH`:**

   ```sh
   git clone https://github.com/dodokr/tmux-claude-tasks.git
   ln -s "$PWD/tmux-claude-tasks/claude-tasks" ~/.local/bin/claude-tasks
   ```

2. **Add the hooks** from [`examples/claude-settings.json`](examples/claude-settings.json) to
   `~/.claude/settings.json`. If you have no other hooks, you can merge it with jq:

   ```sh
   jq -s '.[0] * .[1]' ~/.claude/settings.json tmux-claude-tasks/examples/claude-settings.json \
     > /tmp/settings.json && mv /tmp/settings.json ~/.claude/settings.json
   ```

   (`*` replaces existing hook arrays with the same event name — merge by hand if you already
   use hooks.) Restart running Claude sessions, or check `/hooks`, so they load the new hooks.

3. **Bind a key in tmux** (see [`examples/tmux.conf`](examples/tmux.conf)):

   ```tmux
   bind C-i display-popup -E -w 104 -h 60% "~/.local/bin/claude-tasks"
   ```

   Terminals send `C-i` as `Tab`, so this also takes over `prefix + Tab`. Pick another key if
   you use that.

## Usage

Press your binding (`prefix + C-i` above) to open the picker.

| Key | Action |
| --- | --- |
| `j` / `k` | move down / up |
| `g` / `G` | first / last |
| `Enter` | jump to that pane |
| `dd` | clear the entry (mark it seen → `idle`) |
| `r` | refresh |
| `/` | filter; `Esc` returns to normal mode |
| `q`, `Esc`, `Ctrl+[` | close |

A `done` entry stays until you clear it with `dd`, or until you send that session a new prompt.

### Statuses

| Status | Set by hook | Meaning |
| --- | --- | --- |
| `idle` | `SessionStart`, or `dd` | Session open, nothing to look at |
| `running` | `UserPromptSubmit`, `PostToolUse` after a prompt | Claude is working |
| `waiting` | `Notification` (`permission_prompt`, `elicitation_dialog`) | Claude needs your answer |
| `done` | `Stop` | Claude finished its reply |
| *(removed)* | `SessionEnd` | Session closed |

The "Claude is waiting for your input" idle reminder is ignored, so it never turns `done` into
`waiting`.

### Commands

```text
claude-tasks              open the picker (meant for: tmux display-popup -E)
claude-tasks hook EVENT   record a hook event (Claude Code hook JSON on stdin)
claude-tasks list         print sessions (used by the picker)
claude-tasks clear PANE   mark a session seen (any status -> idle)
claude-tasks jump PANE    switch the current tmux client to that pane
```

### State

One small file per tmux pane in `$CLAUDE_TASKS_DIR`
(default `${XDG_STATE_HOME:-~/.local/state}/claude-tasks/`), containing
`status<TAB>epoch<TAB>cwd`. Files whose pane no longer exists are pruned whenever the list is
shown.

## Tips

- **Silence Claude's own bell.** Claude Code rings the terminal bell when it finishes, and
  tmux/your terminal may turn that into a desktop notification. To rely on `claude-tasks`
  alone, set *Notifications* to disabled in Claude Code's `/config`.
- **Interrupted tasks** (Esc in Claude) may not fire `Stop`, leaving the entry `running` — `dd`
  resets it.

## Development

```sh
scripts/demo.sh            # try the picker on an isolated tmux server with fake sessions
CAPTURE_ANSI=1 scripts/demo.sh --capture | scripts/ansi2svg.py > docs/screenshot.svg
```

The demo runs on its own tmux socket and a temporary state directory, so it never touches
your real sessions.

## License

[MIT](LICENSE)
