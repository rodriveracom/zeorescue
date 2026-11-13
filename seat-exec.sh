#!/bin/sh
# The first program in a seat's pane. rescue.sh starts it with respawn-pane, AFTER it has set @zeo_seat on the pane, so the seat
# loader in ~/.zshrc reads the right label the first time it runs.
#
# The clean environment is the point. A tmux server keeps the environment of whoever started it, so without env -i a seat inherits
# the rescuer's, and a Codex seat without --no-daemon joins a shared app-server that runs every seat's tools under the first seat's
# ZMAIL_INSTANCE and git settings (25 Oct and 5 Nov 2026).
#
#   seat-exec.sh SEAT HARNESS PROMPT_FILE ARGV...
seat=$1 prompt_file=$3
shift 3
prompt=$(cat "$prompt_file") || exit 1
# The seat loader in .zshrc must run here for both harnesses, so its settings are in the process and every tool shell inherits them.
# Codex uses its shell snapshot only in the thread's own directory and with -lc, so a snapshot alone misses its other shells (6 Nov 2026).
exec env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" SHELL=/bin/zsh TERM="${TERM:-xterm-256color}" LANG="${LANG:-en_US.UTF-8}" \
  TMUX="$TMUX" TMUX_PANE="$TMUX_PANE" ZMAIL_INSTANCE="$seat" /bin/zsh -lic 'exec "$@"' zeo-rescue "$@" "$prompt"
