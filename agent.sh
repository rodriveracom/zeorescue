#!/bin/bash
# The rescue seat, detached: a Claude session on its own tmux socket, for a connection that may drop. It shares nothing with zeo2, so
# it does not depend on what crashed. It ends when its work is done; nothing restarts it. Plain `claude` in this directory is the same seat.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
TMUX_BIN=${ZEO_RESCUE_TMUX:-/opt/homebrew/bin/tmux}
CLAUDE=${ZEO_RESCUE_CLAUDE:-$HOME/.local/bin/claude}
if "$TMUX_BIN" -L zeo-rescue has-session -t '=zeo-rescue' 2>/dev/null; then echo "the rescue seat is already up: tmux -L zeo-rescue attach"; exit 0; fi
env -u TMUX "$TMUX_BIN" -L zeo-rescue new-session -d -s zeo-rescue -c "$HERE" -- \
  /bin/zsh -ic 'exec "$@"' zeo-rescue "$CLAUDE" --permission-mode auto \
  "You are the rescue seat. Follow the boot sequence in AGENTS.md." || exit 1
echo "the rescue seat is up: tmux -L zeo-rescue attach"
