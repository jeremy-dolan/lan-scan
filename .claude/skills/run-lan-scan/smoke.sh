#!/usr/bin/env bash
# Drive the lan-scan curses TUI headlessly under tmux and capture each screen.
#
# Uses REVIEW MODE (`--load-previous`): rehydrates the most recent saved run
# from ~/.cache/lan-scan/history/ and opens the exact same CursesUI presenter
# the live scan uses — device list, detail popup, help popup — but with NO
# network traffic, NO nmap, and NO sudo prompt. This is the only way to drive
# the TUI deterministically in a sandbox/CI, and it exercises the layer most
# UI PRs touch (popup rendering, render-time name/kind resolution).
#
# Usage:
#   ./smoke.sh                 # drive review-mode TUI, dump screens, also smoke --print-previous
#
# Screens land in $OUT (default: <repo>/untracked-lan-scan-smoke/, which the
# repo's .gitignore ignores via the untracked-* rule). Each is a plain
# text tmux pane capture — the TUI equivalent of a screenshot. cat them to read.
#
# Requires: tmux, and at least one saved run in ~/.cache/lan-scan/history/.
# If history is empty, run a real scan once first: ./lan-scan --print
set -euo pipefail

# Resolve the lan-scan executable: repo root is three dirs up from this skill
# (.claude/skills/run-lan-scan/ -> repo root).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BIN="$ROOT/lan-scan"
OUT="${OUT:-$ROOT/untracked-lan-scan-smoke}"
S="lanscan_smoke_$$"
# Terminal geometry. Override to exercise width-dependent rendering:
#   COLS=80 LINES=50 ./smoke.sh
COLS="${COLS:-100}"
LINES="${LINES:-30}"

[ -x "$BIN" ] || { echo "FAIL: $BIN not found/executable" >&2; exit 1; }
command -v tmux >/dev/null || { echo "FAIL: tmux not installed (brew install tmux)" >&2; exit 1; }
if ! ls "$HOME/.cache/lan-scan/history/"*.json >/dev/null 2>&1; then
  echo "FAIL: no saved runs in ~/.cache/lan-scan/history/ — run './lan-scan --print' once first" >&2
  exit 1
fi

mkdir -p "$OUT"
cleanup() { tmux kill-session -t "$S" 2>/dev/null || true; }
trap cleanup EXIT

cap() { tmux capture-pane -t "$S" -p > "$OUT/$1"; echo "  captured $OUT/$1"; }

echo "== launching TUI in review mode (tmux ${COLS}x${LINES}) =="
tmux kill-session -t "$S" 2>/dev/null || true
tmux new-session -d -s "$S" -x "$COLS" -y "$LINES"
tmux send-keys -t "$S" "$BIN --load-previous" Enter
sleep 3

echo "== 1. device list =="
cap screen-1-list.txt
grep -q "ADDRESS" "$OUT/screen-1-list.txt" || { echo "FAIL: device list header not rendered" >&2; exit 1; }
grep -q "navigate" "$OUT/screen-1-list.txt" || { echo "FAIL: footer not rendered" >&2; exit 1; }

echo "== 2. detail popup (Down Down ENTER) =="
tmux send-keys -t "$S" Down Down Enter
sleep 1
cap screen-2-detail.txt
grep -q "Device Details:" "$OUT/screen-2-detail.txt" || { echo "FAIL: detail popup did not open" >&2; exit 1; }

echo "== 3. help popup (ENTER closes detail, then ?) =="
tmux send-keys -t "$S" Enter   # close detail popup
sleep 0.5
tmux send-keys -t "$S" "?"
sleep 1
cap screen-3-help.txt
grep -q "Help" "$OUT/screen-3-help.txt" || { echo "FAIL: help popup did not open" >&2; exit 1; }

echo "== 4. quit (q closes help, q quits app) =="
tmux send-keys -t "$S" "q"     # close help popup
sleep 0.5
tmux send-keys -t "$S" "q"     # quit from list
sleep 1.5
# The tmux session outlives lan-scan (it's the shell that hosts it), so we
# confirm the *TUI* exited by checking its footer is gone from the pane.
if tmux capture-pane -t "$S" -p | grep -q "navigate"; then
  echo "FAIL: TUI footer still present — quit did not take" >&2
  exit 1
fi
echo "  TUI exited cleanly (returned to shell)"

echo "== 5. non-TUI sanity: --print-previous =="
"$BIN" --print-previous > "$OUT/print-previous.txt" 2>&1
grep -q "device(s)" "$OUT/print-previous.txt" || { echo "FAIL: --print-previous produced no device table" >&2; exit 1; }
echo "  --print-previous ok"

echo
echo "PASS — screens in $OUT/"
ls -1 "$OUT"
