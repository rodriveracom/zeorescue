#!/bin/bash
# Write the unified log around a crash to a file, for the rescue seat to read. Nobody has to read it or paste it: the seat runs
# /usr/bin/log only through this, because reading the log needs root or Full Disk Access, and the output is too long to share.
#
#   teardown-log.sh [START END]     times as 'YYYY-MM-DD HH:MM:SS', local; default: the 2026-11-05 teardown
#
# The log keeps the default level for days, and --info for much less, so run it soon after a crash.
set -uo pipefail
START=${1:-2026-11-05 05:09:30}
END=${2:-2026-11-05 05:11:00}
STATE=${ZEO_RESCUE_STATE:-$HOME/.local/state/zeo-rescue}
mkdir -p "$STATE" && chmod 700 "$STATE" || exit 1
OUT=$STATE/teardown-$(printf %s "$START" | tr -d ' :-').log
echo "writing $OUT"
sudo /usr/bin/log show --start "$START" --end "$END" --info --style compact > "$OUT"
rc=$?
echo "$(wc -l < "$OUT" | tr -d ' ') lines in $OUT (exit $rc). Tell the rescue seat it is there; it reads the file itself."
exit $rc
