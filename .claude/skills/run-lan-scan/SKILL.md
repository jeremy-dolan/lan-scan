---
name: run-lan-scan
description: Run, launch, build, drive, or screenshot the lan-scan curses TUI (a stdlib-only Python network discovery tool). Use to start the app, capture its screens (device list / detail popup / help popup), smoke-test the UI headlessly under tmux, or directly call its internal name/kind resolvers and IPP/packet parsers without a live scan.
---

# Run lan-scan

`lan-scan` is a single self-contained Python 3 executable (stdlib only, no deps,
no build step) that discovers LAN devices and shows them in a curses TUI. There
is nothing to compile — you run the script directly.

The hard part is driving the **curses TUI** headlessly. The driver for that is
[`.claude/skills/run-lan-scan/smoke.sh`](smoke.sh): it launches the app under
tmux in **review mode**, walks the device list → detail popup → help popup, and
dumps each screen to a text file (the TUI equivalent of a screenshot).

All paths below are relative to the repo root (the directory containing the
`lan-scan` executable).

## Why review mode

A live scan needs **a real terminal** (sudo prompts for the nmap ARP sweep) and
**real LAN multicast access**. Neither exists in a sandbox — sudo aborts with
"a terminal is required" and the multicast sockets get `OSError: [Errno 65] No
route to host`. So the driver uses `--load-previous`, which rehydrates the most
recent saved run from `~/.cache/lan-scan/history/` and opens the **exact same**
`CursesUI` presenter — list, detail popup, help popup — with zero network
traffic and zero sudo. This is the layer most UI PRs touch (popup rendering,
render-time name/kind resolution).

## Prerequisites

```bash
tmux -V            # tmux 3.6b — driver needs it (brew install tmux on macOS)
python3 --version  # 3.14.5 here; needs a modern Python 3 (uses dict[str,int] syntax)
```

No `pip install` — the app is stdlib-only.

The driver needs **at least one saved run** in `~/.cache/lan-scan/history/`.
This repo's machine already has dozens. To create one from scratch on a machine
with real LAN access: `./lan-scan --print` (writes a history JSON as a
side effect).

## Run (agent path) — drive the TUI

```bash
.claude/skills/run-lan-scan/smoke.sh
```

It prints PASS and leaves four files in `untracked-lan-scan-smoke/` (gitignored
via the repo's `untracked-*` rule):

- `screen-1-list.txt` — the device list (header, rows, "Missing since last run", footer)
- `screen-2-detail.txt` — the per-device detail popup (ENTER on a row)
- `screen-3-help.txt` — the help popup (`?`)
- `print-previous.txt` — the non-TUI `--print-previous` table (sanity check)

Inspect any screen with `cat untracked-lan-scan-smoke/screen-2-detail.txt`.

The driver asserts the right text appears on each screen and that the TUI quits
cleanly, so a non-zero exit or missing `PASS` means a regression. To drive it by
hand or add steps, the key sequence is: arrows / `j`/`k` move the selection,
`ENTER` opens the detail popup, `ENTER`/`q`/`ESC` closes it, `?` opens help,
`q`/`ESC`/`ENTER` closes help, and `q` from the list quits.

### tmux one-liner (manual poke)

```bash
S=lanscan; tmux new-session -d -s $S -x 100 -y 30
tmux send-keys -t $S "$PWD/lan-scan --load-previous" Enter; sleep 3
tmux capture-pane -t $S -p          # see the device list
tmux send-keys -t $S Down Down Enter; sleep 1
tmux capture-pane -t $S -p          # see the detail popup
tmux send-keys -t $S q q            # close popup, quit
tmux kill-session -t $S
```

## Direct invocation — call internals without the app

The executable has no `.py` extension, but everything is gated under
`if __name__ == "__main__"`, so it imports cleanly. This is the fastest path for
PRs that touch a pure function (name/kind resolution, the manufacturer+model
redundancy guard, IPP/packet parsing):

```bash
python3 - <<'PY'
import importlib.util, importlib.machinery
loader = importlib.machinery.SourceFileLoader("lanscan", "./lan-scan")
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("lanscan", loader))
loader.exec_module(m)

d = m.Device("192.168.1.61")
d.upnp_room_name = "Kitchen"
d.mdns_a_name = "Sonos-347E5C10C79A"
print(m.resolve_name(d))              # -> Kitchen
print(m.resolve_device_kind(d))       # -> [unknown device]
print(m._manufacturer_is_redundant)   # the redundancy-guard fn
PY
```

## Non-TUI modes (verified)

```bash
./lan-scan --help            # usage text, exit 0
./lan-scan --setup-sudoers   # prints the NOPASSWD sudoers line, exit 0
./lan-scan --print-previous  # prints the most recent saved run as a table, exit 0
./lan-scan --print --new-scan  # conflicting mode flags -> "Pick one.", exit 2
```

## Run (human path)

`./lan-scan` (no args) opens an interactive curses menu (new scan vs. load a
past run). `./lan-scan --new-scan` scans immediately in the TUI. Both need a
real terminal and real LAN access — useless headless (see Gotchas). For a live
scan from a stdout, `./lan-scan --print`.

## Gotchas

- **The tmux session outlives the app.** The session hosts a shell that *runs*
  `lan-scan`; quitting the TUI drops back to the shell, so `tmux has-session`
  still reports alive. To confirm the TUI actually quit, capture the pane and
  check its footer (`navigate …`) is gone — that's what the driver does.
- **Live scan is a non-starter in a sandbox.** `--print`/`--new-scan` hit a sudo
  prompt that needs a tty *and* multicast sockets that need a real LAN. In a
  sandbox you get `sudo: a terminal is required` then
  `OSError: [Errno 65] No route to host`. Use `--load-previous` / `--print-previous`.
- **The popup overlays the list, it doesn't replace it.** In a captured screen
  the popup box is drawn *on top of* the device rows, so each line reads like
  `192.168.1.┌── Device Details …`. That's correct rendering, not corruption.
- **Terminal width matters.** The driver defaults to 100×30; override with the
  `COLS` / `LINES` env vars (`COLS=80 LINES=50 ./smoke.sh`) to exercise
  width-dependent rendering. The two popups handle a narrow terminal
  differently: the detail popup **truncates** long lines to the width, while
  the help popup **word-wraps** its prose to fit (only its preformatted key
  table can clip).
- **`--setup-sudoers` is subnet-agnostic.** The emitted sudoers line matches the
  nmap args with a regex (`ARP_SUDOERS_ARGS`), so it keeps working across subnet
  changes — no regeneration needed. The regex match requires sudo >= 1.9.10.

## Troubleshooting

- `FAIL: no saved runs in ~/.cache/lan-scan/history/` — the driver needs a prior
  run to replay. On a machine with LAN access, run `./lan-scan --print` once.
- `command not found: timeout` — macOS has no `timeout` (it's `gtimeout` from
  coreutils). The driver doesn't use it; if you add it, install coreutils or use
  `gtimeout`.
- `FAIL: tmux not installed` — `brew install tmux`.
- Detail popup doesn't open in a manual run — wait ~1s after `Down Down Enter`
  before `capture-pane`. `send-keys` returns the instant it queues the keys; it
  doesn't wait for the app to wake from its blocking getch, handle them, and
  repaint, so an immediate capture races the redraw and grabs the old screen.
