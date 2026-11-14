#!/bin/bash
# model-answered.sh LOG [WAIT_SECONDS]: did each seat a run restarted get an answer from its model? It reads only.
# A seat is every "RESUMED SEAT: HARNESS SESSION (...) in SESSION at TIME" line of LOG. TIME is when that seat was started, and only
# records written after that second count, so nothing the old process wrote before its stop is taken for an answer.
#   ANSWERED  the newest verdict after the start is an assistant message from the model (not Claude's own synthetic stand-in)
#   ERROR     the newest verdict after it is a turn that ended in an error, or an API error message; the error is shown.
#             A later error wins over an earlier answer, and a later answer over an earlier error.
#   STOPPED   the run itself stopped the seat again after it was started, because its proof failed (a "STOPPED: SEAT:" line)
#   WAITING   neither yet, after WAIT_SECONDS (default 0)
# A process that is up proves nothing about the model: on 10 Nov every Codex seat was up and every request failed.
# Exit: 0 every seat ANSWERED, or none was restarted; 1 any ERROR or STOPPED; 2 any still WAITING; 3 a seat's record or start time
# cannot be found.
set -uo pipefail
log=${1:-} wait=${2:-0}
[ -r "$log" ] && [[ "$wait" =~ ^[0-9]+$ ]] || { echo "usage: model-answered.sh LOG [WAIT_SECONDS]" >&2; exit 2; }
SESSIONS=${ZEO_RESCUE_CODEX_SESSIONS:-$HOME/.codex/sessions}
PROJECTS=${ZEO_RESCUE_PROJECTS:-$HOME/.claude/projects}
TAIL=${ZEO_RESCUE_ANSWER_TAIL:-8000000} # the end of a rollout is enough, and one is 1.7 GB
PAUSE=${ZEO_RESCUE_ANSWER_PAUSE:-5}

seats=() harn=() files=() sinces=()
missing=0 stopped=0 out0=""
while IFS= read -r line; do
  read -r _ seat h sid _ <<< "$line"; seat=${seat%:}
  at=$(printf '%s\n' "$line" | sed -nE 's/.* at ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z$/\1/p')
  if [ -z "$at" ]; then echo "NO START TIME $seat: its RESUMED line does not say when it was started, so no record can be told from the old process's"; missing=1; continue; fi
  if /usr/bin/grep -qF "STOPPED: $seat: " "$log"; then out0+="STOPPED $seat ($h): the run stopped it again after it was started"$'\n'; stopped=$((stopped+1)); continue; fi
  case "$h" in
    codex) f=$(/usr/bin/find "$SESSIONS" -name "rollout-*-$sid.jsonl" 2>/dev/null | head -1);;
    claude) f=$(/usr/bin/find "$PROJECTS" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1);;
    *) f="";;
  esac
  if [ -z "$f" ]; then echo "NO RECORD $seat: no $h record for $sid"; missing=1; continue; fi
  seats+=("$seat") harn+=("$h") files+=("$f") sinces+=("$at")
done < <(/usr/bin/grep -E '^RESUMED [^ ]+: (codex|claude) [0-9a-f-]+ ' "$log")
if [ ${#seats[@]} -eq 0 ] && [ $stopped -eq 0 ]; then
  [ $missing -eq 0 ] || exit 3; echo "no seat was restarted in $log, so there is no answer to wait for"; exit 0
fi

verdict() { # verdict HARNESS FILE SINCE: prints ANSWERED, ERROR <text>, or WAITING, from the newest verdict after SINCE (to the second)
  tail -c "$TAIL" "$2" | /usr/bin/awk -v s="$3" -v h="$1" '
    { if (!match($0, /"timestamp":"[0-9T:.-]+/)) next; t = substr(substr($0, RSTART + 13, RLENGTH - 13), 1, 19); if (t <= s) next }
    h == "codex" && /"type":"response_item"/ && /"role":"assistant"/ { last = "A"; next }
    h == "codex" && /"type":"task_complete"/ && /"error":\{/ { last = "E"; e = $0; next }
    h == "claude" && /"type":"assistant"/ {
      if (/"isApiErrorMessage":true/) { last = "E"; e = $0 }
      else if (/"model":"/ && !/"model":"<synthetic>"/) last = "A" }
    END {
      if (last == "A") { print "ANSWERED"; exit }
      if (last == "E") { m = e; if (match(e, /"message":"[^"]*/)) m = substr(e, RSTART + 11, RLENGTH - 11); if (match(e, /The [^\\"]*/)) m = substr(e, RSTART, RLENGTH); print "ERROR " substr(m, 1, 200); exit }
      print "WAITING" }'
}

deadline=$(( $(/bin/date +%s) + wait ))
while :; do
  answered=0 errors=0 waiting=0 out=""
  for i in "${!seats[@]}"; do
    v=$(verdict "${harn[$i]}" "${files[$i]}" "${sinces[$i]}")
    case "$v" in ANSWERED) answered=$((answered+1));; ERROR*) errors=$((errors+1));; *) waiting=$((waiting+1));; esac
    case "$v" in ERROR*) out+="ERROR ${seats[$i]} (${harn[$i]}): ${v#ERROR }"$'\n';; *) out+="$v ${seats[$i]} (${harn[$i]})"$'\n';; esac
  done
  [ $waiting -gt 0 ] && [ "$(/bin/date +%s)" -lt "$deadline" ] || break
  sleep "$PAUSE"
done
printf '%s%s' "$out0" "$out"
echo "answered: $answered of $(( ${#seats[@]} + stopped )), error $errors, stopped $stopped, waiting $waiting"
[ $errors -eq 0 ] && [ $stopped -eq 0 ] || exit 1
[ $missing -eq 0 ] || exit 3
[ $waiting -eq 0 ] || exit 2
exit 0
