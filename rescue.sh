#!/bin/bash
# zeo-rescue: bring the org's seats back after a crash, from system tools alone.
#
# It runs only when asked. It needs bash, jq, tmux, sqlite3, ps, lsof and the harness CLIs, and it does NOT need Messenger, the
# wake daemons or the collector: those are what may be down. Without --apply it starts nothing and prints the plan.
#
#   rescue.sh [--apply [--break-stale-lock]] [--reseat] [--relaunch] [--restart] [--upgrade] [--except ID]... [--check] [--harness claude|codex|all] [--seat ID]... [--session ID] [--note-file F] [--before YYYYMMDDHHMM] [--host H] [--socket S] [--stagger SECONDS] [--chart FILE]
#
# --apply runs alone: it holds $STATE/apply.lock from before the plan to the end, and a second --apply refuses while the first runs. A lock
# whose holder is gone is reported, never broken silently; --break-stale-lock breaks that one lock. A run kills only a tmux session its own
# new-session created, and just before each start it reads the seat again (the plan is minutes old by then), leaving it alone if it changed.
#
# The host is --host, else ZEO_RESCUE_HOST, else the first line of $STATE/host-name, else hostname -s: the name the chart's desired_host uses.
#
# For each seat of the chart on this host it decides one of:
#   LIVE        its tmux session exists                         left alone
#   RUNNING     a process of its harness runs in its directory  left alone: two processes on one transcript corrupt each other
#   RESUME      dead, with a session and a recorded mode        resumed with --apply
#   UNRESOLVED  dead, and something needed is missing           left alone and named: this is the agent stage's work
#
# --reseat also restarts LIVE seats that rescue did not start the right way: RESEAT, or OK when the pane already carries @zeo_rescue.
# --relaunch, with --reseat, also restarts a seat rescue started, if its process lacks the seat settings or it is not yet in its folder.
# A seat with everything right is left alone, so the same line can be run again after a stop.
# --restart, with --relaunch, exactly one --seat and a --note-file, restarts that seat even when it reads as right, so the note reaches it.
# Its line must keep itself from running twice; rescue cannot tell a restart done from one still to do.
# --upgrade, with --relaunch, also restarts a seat rescue started when its process runs a binary other than the one its harness CLI resolves to
# now, as after `codex update` or `claude update`; the binary is read from the process itself (lsof), not from its command line, which names
# the unchanged symlink. The seat is told why. A seat already on the installed binary is left alone, so its line can run again.
# An upgrade never moves or carries a seat, whatever folder-moves says: it restarts a live seat in the folder its process works in now, which
# must be its chart folder or, once moved, its line's folder; anywhere else is UNRESOLVED. A seat that is down is named DOWN and left to make rescue.
# --except ID leaves that seat out of the run entirely: the Architect, whose own restart waits for a break the operator chooses.
# folder-moves holds a line "SEAT /new/folder" for a Codex seat that leaves the chart's folder. The thread stays the seat's: Codex rewrites a
# thread's folder when it resumes elsewhere, so a seat moves only if session-pins names its thread. Otherwise a later plan would miss the thread.
# A folder in git needs a trust entry first, or Codex stops at a question nobody may answer. Every move is proved before the next seat starts.
# A Claude seat moves the same way, with one difference: its whole project under ~/.claude/projects goes by one rename while it is stopped, so
# its memory, which is keyed to the folder, comes too. Claude needs a trust entry for any folder, and a worktree target is refused: no such move is proved.
# A line "SEAT /new/folder carry" moves the seat's own clone to the new path while the seat is stopped, which is how <org>/<repo> becomes
# <org>/<repo>/main. It is a rename, not a copy: the same folder, branch, uncommitted and ignored files. The plan refuses unless the clone is an
# ordinary one with its own .git, the new path is free on the same volume and not inside another repository, its trust entry is in place, and
# only the seat's own processes work inside the clone. After the rename its linked worktrees elsewhere are repaired, and each must reach it.
# A line "SEAT /new/folder carry-plain" carries an ops seat's plain folder the same way (the Architect's order of 9 Nov 11:28Z): a folder not
# in git, holding clones of its own. Each clone in it must be an ordinary one with its own .git, its config must not name the folder, and
# none may have a linked worktree inside it; a .git file in it is refused. After the rename each clone must read the same, and its linked
# worktrees elsewhere are repaired.
# A seat that is down is not carried: the stop must be this run's own.
# --check starts nothing and judges every seat: OK or WRONG, with the reason. It reads the running process and a fresh shell in another
# folder given the process's own settings, not only the snapshot, because Codex uses the snapshot only in the thread's directory and with -lc.
# It lists what a restart would cut first, as WORK lines, in the plan and again just before --apply stops anything.
# --session ID (with exactly one --seat) names the session to resume. Use it when the newest transcript in a seat's directory is not
# the seat's own, such as after someone ran another session there.
# session-pins holds the same answer, durably: a line "SEAT SESSION-ID" for a seat whose newest transcript is known not to be its own.
# --before limits the search for a recorded marker to files older than that local time, when newer ones were written during a fault.
#
# Three things are read from the seat's own record and never chosen here:
#   the session     its newest transcript or thread, or --session
#   the mode        Claude's permissionMode; Codex's approval and sandbox policies (3 of 35 Codex seats ran workspace-write)
#   the git marker  @zeo_seat, from its newest shell snapshot. Without a pane marker the seat loader turns git and gh off, so a seat
#                   recorded as inactive stays inactive. A seat with no record in a snapshot (every Claude seat: its snapshots keep
#                   no exports) needs an explicit line "SEAT MARKER" in seat-markers (master, sparring, principal or inactive), written
#                   on the Architect's word. Nothing is inferred: with neither, the seat is UNRESOLVED and named, never given a default.
#
# A Codex seat starts only when no process holds its rollout. Its own client going away proves little: the shared daemon keeps every
# thread open, so a seat started beside it would be a second writer. A seat refused this way stays down, and the run says who holds it.
# A first seat that fails its proof is stopped again and loses @zeo_rescue, so the next run plans it again; RECOVERY says what is down.
#
# Exit: 0 every seat fine or resumable; 1 a failure, or a --check found WRONG; 2 usage; 3 at least one seat UNRESOLVED.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
STATE=${ZEO_RESCUE_STATE:-$HOME/.local/state/zeo-rescue}
# The org chart: ZEO_RESCUE_CHART, or a link at $STATE/ORG-CHART.json to the host's live chart. The tables below are host records,
# kept beside it in the private state folder, never in this repository.
CHART=${ZEO_RESCUE_CHART:-$STATE/ORG-CHART.json}
PROJECTS=${ZEO_RESCUE_PROJECTS:-$HOME/.claude/projects}
CODEX_DB=${ZEO_RESCUE_CODEX_DB:-$HOME/.codex/state_5.sqlite}
SNAPSHOTS=${ZEO_RESCUE_SNAPSHOTS:-$HOME/.codex/shell_snapshots}
TMUX_BIN=${ZEO_RESCUE_TMUX:-/opt/homebrew/bin/tmux}
JQ=${ZEO_RESCUE_JQ:-/opt/homebrew/bin/jq}
SQLITE=${ZEO_RESCUE_SQLITE:-/usr/bin/sqlite3}
PS_BIN=${ZEO_RESCUE_PS:-/bin/ps}
LSOF=${ZEO_RESCUE_LSOF:-/usr/sbin/lsof}
KILL_BIN=${ZEO_RESCUE_KILL:-/bin/kill}
CLAUDE=${ZEO_RESCUE_CLAUDE:-$HOME/.local/bin/claude}
CODEX=${ZEO_RESCUE_CODEX:-$HOME/.local/bin/codex}
ZSH_BIN=${ZEO_RESCUE_ZSH:-/bin/zsh}
SESSIONS=${ZEO_RESCUE_SESSIONS:-$HOME/.codex/sessions}
CODEX_CONFIG=${ZEO_RESCUE_CODEX_CONFIG:-$HOME/.codex/config.toml}
CLAUDE_JSON=${ZEO_RESCUE_CLAUDE_JSON:-$HOME/.claude.json}
PROOF_TRIES=${ZEO_RESCUE_PROOF_TRIES:-24}
PROOF_PAUSE=${ZEO_RESCUE_PROOF_PAUSE:-5}
STOP_TRIES=${ZEO_RESCUE_STOP_TRIES:-30}
SOCKET=zeo2 HOST_NAME=${ZEO_RESCUE_HOST:-$(head -n 1 "$STATE/host-name" 2>/dev/null || hostname -s)} HARNESS=all STAGGER=20 APPLY=0 ONLY=" " RESEAT=0 RELAUNCH=0 RESTART=0 UPGRADE=0 EXCEPT=" " CHECK=0 SESSION="" SESSION_ARG="" NOTE_FILE="" BEFORE="" BREAK_STALE=0
PINS=${ZEO_RESCUE_PINS:-$STATE/session-pins}
MOVES=${ZEO_RESCUE_MOVES:-$STATE/folder-moves}
MARKERS=${ZEO_RESCUE_MARKERS:-$STATE/seat-markers}
PROMPT="You were restarted: this host's login session was torn down and your session was lost. Your history is resumed. Check your mail (zmsg inbox), answer what is owed (zmsg pending), then continue the work you were doing. Do not repeat any outward action your history shows you already completed."

UPROMPT="You were restarted so that you run the newer harness installed on this host (%s); the one you were running was older. Nothing else changed, and your history is resumed. Check your mail (zmsg inbox), answer what is owed (zmsg pending), then continue the work you were doing. Do not repeat any outward action your history shows you already completed."
usage() { sed -n '/^#   rescue.sh/p' "$0" >&2; exit 2; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --break-stale-lock) BREAK_STALE=1; shift;;
    --reseat) RESEAT=1; shift;;
    --relaunch) RELAUNCH=1; shift;;
    --restart) RESTART=1; shift;;
    --upgrade) UPGRADE=1; shift;;
    --except) [ $# -ge 2 ] || usage; EXCEPT="$EXCEPT$2 "; shift 2;;
    --check) CHECK=1; shift;;
    --harness) [ $# -ge 2 ] || usage; HARNESS=$2; shift 2;;
    --seat) [ $# -ge 2 ] || usage; ONLY="$ONLY$2 "; shift 2;;
    --session) [ $# -ge 2 ] || usage; SESSION_ARG=$2; shift 2;;
    --note-file) [ $# -ge 2 ] || usage; NOTE_FILE=$2; shift 2;;
    --before) [ $# -ge 2 ] || usage; BEFORE=$2; shift 2;;
    --host) [ $# -ge 2 ] || usage; HOST_NAME=$2; shift 2;;
    --socket) [ $# -ge 2 ] || usage; SOCKET=$2; shift 2;;
    --stagger) [ $# -ge 2 ] || usage; STAGGER=$2; shift 2;;
    --chart) [ $# -ge 2 ] || usage; CHART=$2; shift 2;;
    *) usage;;
  esac
done
case "$HARNESS" in claude|codex|all) ;; *) usage;; esac
[[ "$STAGGER" =~ ^[0-9]+$ ]] || usage
[ -z "$BEFORE" ] || [[ "$BEFORE" =~ ^[0-9]{12}$ ]] || usage
[ $CHECK -eq 0 ] || { [ $APPLY -eq 0 ] && [ $RESEAT -eq 0 ]; } || usage
[ $RELAUNCH -eq 0 ] || [ $RESEAT -eq 1 ] || usage
[ $BREAK_STALE -eq 0 ] || [ $APPLY -eq 1 ] || usage
[ $UPGRADE -eq 0 ] || [ $RELAUNCH -eq 1 ] || usage
if [ $RESTART -eq 1 ]; then
  [ $RELAUNCH -eq 1 ] && [ -n "$NOTE_FILE" ] || usage
  n=0; for w in $ONLY; do n=$((n+1)); done
  [ "$n" -eq 1 ] || { echo "rescue: --restart needs exactly one --seat" >&2; exit 2; }
fi
ID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [ -n "$SESSION_ARG" ]; then
  [[ "$SESSION_ARG" =~ $ID_RE ]] || usage
  n=0; for w in $ONLY; do n=$((n+1)); done
  [ "$n" -eq 1 ] || { echo "rescue: --session needs exactly one --seat" >&2; exit 2; }
fi
[ -z "$NOTE_FILE" ] || [ -r "$NOTE_FILE" ] || { echo "rescue: cannot read $NOTE_FILE" >&2; exit 2; }
[[ "$SOCKET" =~ ^[a-z0-9][a-z0-9_-]{0,39}$ ]] || { echo "rescue: bad socket name $SOCKET" >&2; exit 2; }
for t in "$JQ" "$TMUX_BIN" "$PS_BIN"; do [ -x "$t" ] || { echo "rescue: missing tool $t" >&2; exit 1; }; done

# --upgrade: the binary each harness CLI resolves to now, through every symlink. A seat's process that does not map it runs an older one.
installed() { /usr/bin/perl -MCwd=abs_path -e 'my $p = abs_path($ARGV[0]); (defined $p && -f $p && -x $p) or exit 1; print $p' "$1"; }
CUR_codex="" CUR_claude="" RUN_BIN=""
if [ $UPGRADE -eq 1 ]; then
  [ -x "$LSOF" ] || { echo "rescue: --upgrade needs lsof to read which binary a seat runs; missing $LSOF" >&2; exit 1; }
  if [ "$HARNESS" != claude ]; then CUR_codex=$(installed "$CODEX") || { echo "rescue: --upgrade: $CODEX resolves to no executable file" >&2; exit 1; }; fi
  if [ "$HARNESS" != codex ]; then CUR_claude=$(installed "$CLAUDE") || { echo "rescue: --upgrade: $CLAUDE resolves to no executable file" >&2; exit 1; }; fi
fi
runs_binary() { # runs_binary PID PATH: 0 the process maps PATH, 1 it maps another (RUN_BIN, its harness binary), 2 could not tell
  local out; RUN_BIN=""
  out=$("$LSOF" -p "$1" -a -d txt -Fn 2>/dev/null) && [ -n "$out" ] || return 2
  printf '%s\n' "$out" | grep -xF "n$2" >/dev/null && return 0
  RUN_BIN=$(printf '%s\n' "$out" | sed -n 's/^n//p' | grep -E '/(codex|claude)([^/]*/)*[^/]*$' | head -1)
  [ -n "$RUN_BIN" ] || return 2
  return 1
}

# The chart: the live one when it parses, and it becomes the last good copy; otherwise the last good copy, said out loud.
seats_of() { "$JQ" -e -r --arg h "$HOST_NAME" '.seats | map(select(.desired_host == $h and (.desired_agent == "claude" or .desired_agent == "codex"))) | if length == 0 then error("no seats") else .[] end | [.seat_id, .mailbox, .desired_agent, .desired_tmux.session, .desired_folder] | map(. // "-") | join("\u001f")' "$1" 2>/dev/null; }
mkdir -p "$STATE/prompts" && chmod 700 "$STATE" "$STATE/prompts" || { echo "rescue: cannot use $STATE" >&2; exit 1; }

# One --apply at a time. Two runs that planned the same dead seat would start it twice, or one would stop the other's seat. The lock is a
# folder under STATE, taken atomically by mkdir before the plan and held to the end of the run. Its holder file names the pid and that
# pid's start time, so a later process with the same number is not taken for the holder. A lock whose holder is gone is never broken
# silently: the run refuses and says so, and --break-stale-lock breaks exactly that lock, after the operator has seen no rescue runs.
LOCK=$STATE/apply.lock LOCKED=0
started_at() { /bin/ps -o lstart= -p "$1" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//'; }
take_lock() {
  local me holder pid when aside
  me="$$ $(started_at $$)"
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$me" > "$LOCK/holder" || { rmdir "$LOCK" 2>/dev/null; echo "rescue: cannot write $LOCK/holder" >&2; return 1; }
    LOCKED=1; return 0
  fi
  holder=$(head -n 1 "$LOCK/holder" 2>/dev/null)
  [ -n "$holder" ] || { pause 1; holder=$(head -n 1 "$LOCK/holder" 2>/dev/null); } # a run that took it this instant writes its holder next
  pid=${holder%% *} when=${holder#* }
  if [ -z "$holder" ] || ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "LOCKED, nothing was done: $LOCK names no holder; if no rescue runs, run again with --break-stale-lock"; return 1
  fi
  if kill -0 "$pid" 2>/dev/null && [ "$(started_at "$pid")" = "$when" ]; then
    echo "LOCKED, nothing was done: another rescue --apply is running (pid $pid, started $when). Run again once it has ended."; return 1
  fi
  [ $BREAK_STALE -eq 1 ] || { echo "STALE LOCK, nothing was done: $LOCK names pid $pid (started $when), which no longer runs. If no rescue is running, run again with --break-stale-lock."; return 1; }
  aside=$LOCK.stale-$(date +%Y%m%d%H%M%S)-$$
  mv "$LOCK" "$aside" 2>/dev/null || { echo "LOCKED, nothing was done: could not move the stale lock aside"; return 1; }
  if [ "$(head -n 1 "$aside/holder" 2>/dev/null)" != "$holder" ]; then
    mv "$aside" "$LOCK" 2>/dev/null; echo "LOCKED, nothing was done: the lock changed while it was being broken"; return 1
  fi
  echo "STALE LOCK BROKEN: pid $pid (started $when) no longer runs; its lock is kept at $aside"
  mkdir "$LOCK" 2>/dev/null && printf '%s\n' "$me" > "$LOCK/holder" || { echo "LOCKED, nothing was done: another run took the lock first"; return 1; }
  LOCKED=1
}
release_lock() {
  [ $LOCKED -eq 1 ] || return 0
  [ "$(head -n 1 "$LOCK/holder" 2>/dev/null)" = "$$ $(started_at $$)" ] && rm -f "$LOCK/holder" && rmdir "$LOCK"
  LOCKED=0
}
if [ $APPLY -eq 1 ]; then
  take_lock || exit 1
  trap release_lock EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
fi
GOOD=$STATE/ORG-CHART.last-good.json
if rows=$(seats_of "$CHART"); then
  tmp=$(mktemp "$STATE/.chart.XXXXXX") && cp "$CHART" "$tmp" && mv -f "$tmp" "$GOOD"
elif rows=$(seats_of "$GOOD"); then
  echo "rescue: WARNING: $CHART is unreadable; using the last good copy from $(date -r "$GOOD" '+%F %T')" >&2
else
  echo "rescue: no readable org chart at $CHART or $GOOD" >&2; exit 1
fi

PSOUT=$("$PS_BIN" -axo pid=,command=) || { echo "rescue: ps failed" >&2; exit 1; }
ps_line() { printf '%s\n' "$PSOUT" | awk -v p="$1" '$1==p'; }
RUN_ERR=""
running_in() { # running_in HARNESS CWD: 0 yes, 1 no, 2 could not tell (RUN_ERR says why). HARNESS is claude, codex, or any for both.
  # Output that names the folder proves a process there, whatever lsof's exit status. "Nobody here" is accepted only from a clean answer:
  # exit 0 and nothing on stderr. Anything else (any other exit without the folder in the output, any stderr line) is "could not tell":
  # partial output covers only the processes lsof could read, and the one it could not may be the one in the folder. A seat that is
  # really empty is picked up by the next run; a live seat is never started twice. The first stderr line goes into RUN_ERR.
  local pids e out rc
  RUN_ERR=""
  pids=$(printf '%s\n' "$PSOUT" | awk -v h="$1" '{n=split($2,p,"/"); b=p[n]
    if (h == "any") { if (b == "claude" || b == "codex" || $2 ~ /\/(claude|codex)\/versions\//) print $1 }
    else if (b == h || $2 ~ ("/" h "/versions/")) print $1 }' | paste -sd, -)
  [ -n "$pids" ] || return 1
  e=$(mktemp "${TMPDIR:-/tmp}/zeo-lsof.XXXXXX") || { RUN_ERR="could not make a file for lsof's errors"; return 2; }
  out=$("$LSOF" -a -d cwd -Fn -p "$pids" 2>"$e"); rc=$?
  RUN_ERR=$(head -n 1 "$e"); rm -f "$e"
  if printf '%s\n' "$out" | grep -xF "n$2" >/dev/null; then RUN_ERR=""; return 0; fi
  if [ $rc -eq 0 ] && [ -z "$RUN_ERR" ]; then return 1; fi
  RUN_ERR="lsof exited $rc$( [ -n "$out" ] && printf ' without the folder in its output' || printf ' with no output')${RUN_ERR:+: $RUN_ERR}"
  return 2
}
holds() { # holds SID: does a harness process hold this session? 0 yes, 1 no, 2 the process list could not be read.
  # Only harness binaries count: a tmux server keeps the command line of its first client as its title, for life.
  local out; out=$("$PS_BIN" -axo pid=,command=) || return 2
  printf '%s\n' "$out" | awk -v id="$1" '($2 ~ /(^|\/)(claude|codex)$/ || $2 ~ /\/(claude|codex)\/versions\//) && index($0, id) {f=1} END {exit !f}'
}

SID="" MODE_ARGS="" WHY="" SANDBOX="" ROLL=""
project_key() { printf %s "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }
plan_claude() { # sets SID and MODE_ARGS for a Claude seat, or WHY
  local dir f m; dir=$PROJECTS/$(project_key "$1")
  # until it moves, a moving seat's project is still under its old folder
  if [ -n "$OLD_CWD" ] && [ ! -d "$dir" ]; then dir=$PROJECTS/$(project_key "$OLD_CWD"); fi
  # newest top-level transcript by name-safe glob; subagent transcripts live one level down
  if [ -n "$SESSION" ]; then f=$dir/$SESSION.jsonl; [ -f "$f" ] || { WHY="no transcript $f"; return 1; }
  else f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1); fi
  [ -n "$f" ] || { WHY="no transcript in $dir"; return 1; }
  SID=$(basename "$f" .jsonl)
  [[ "$SID" =~ $ID_RE ]] || { WHY="newest transcript has no session id: $f"; return 1; }
  m=$(tail -c 5000000 "$f" | grep -o '"permissionMode":"[^"]*"' | tail -1 | sed -E 's/.*:"([^"]*)"/\1/')
  case "$m" in
    default|auto|acceptEdits|plan) MODE_ARGS="--permission-mode $m";;
    *) WHY="transcript records no permission mode I may reuse ('$m')"; return 1;;
  esac
}
plan_codex() { # sets SID, MODE_ARGS and SANDBOX for a Codex seat, or WHY
  local q row a s lines where roll
  where="cwd = '$(printf %s "$1" | sed "s/'/''/g")'"
  [ -z "$SESSION" ] || where="id = '$SESSION'"
  q="select id || ' ' || rollout_path from threads where $where and archived = 0 and thread_source = 'user' order by updated_at desc limit 1;"
  row=$(db_read "$q") || { WHY="cannot read $CODEX_DB"; return 1; }
  [ -n "$row" ] || { WHY="no Codex thread for this directory"; return 1; }
  # a space, not a control byte: the sqlite3 shell escapes control characters in values, so char(31) arrives as a literal ^_
  SID=${row%% *}; roll=${row#* }
  [[ "$SID" =~ $ID_RE ]] || { WHY="unexpected thread id $SID"; return 1; }
  [ -f "$roll" ] || { WHY="no rollout file $roll"; return 1; }
  lines=$(tail -c 5000000 "$roll" | grep -o '"approval_policy":"[^"]*"\|"sandbox_policy":{"type":"[^"]*"')
  a=$(printf '%s\n' "$lines" | grep approval_policy | tail -1 | sed -E 's/.*:"([^"]*)"/\1/')
  s=$(printf '%s\n' "$lines" | grep sandbox_policy | tail -1 | sed -E 's/.*:"([^"]*)"/\1/')
  case "$a" in never|on-request|untrusted|on-failure) ;; *) WHY="rollout records no approval policy ('$a')"; return 1;; esac
  case "$s" in danger-full-access|workspace-write|read-only) ;; *) WHY="rollout records no sandbox ('$s')"; return 1;; esac
  MODE_ARGS="-a $a -s $s"; SANDBOX=$s ROLL=$roll
}

MARK="" MARK_WHY=""
marker_of() { # marker_of HARNESS SID SEAT: sets MARK (empty means no marker, so git stays off) and MARK_WHY, or fails with WHY
  # The seat's own snapshot first, then its explicit line in seat-markers. There is no default: without either, the seat is UNRESOLVED.
  local f m t lines
  MARK="" MARK_WHY=""
  if [ "$1" = codex ]; then
    for f in $(ls -t "$SNAPSHOTS/$2".* 2>/dev/null); do
      if [ -n "$BEFORE" ]; then t=$(date -r "$f" +%Y%m%d%H%M); [ "$t" -lt "$BEFORE" ] || continue; fi
      m=$(grep -o 'ZEO_TMUX_SEAT=[^ ]*' "$f" | tail -1 | tr -d "\"'"); m=${m#ZEO_TMUX_SEAT=}
      case "$m" in
        master|sparring|principal) MARK=$m MARK_WHY=recorded; return 0;;
        inactive) MARK="" MARK_WHY="recorded inactive"; return 0;;
      esac
    done
  fi
  if [ -e "$MARKERS" ]; then
    lines=$(awk -v s="$3" '$1==s' "$MARKERS" 2>/dev/null) || { WHY="cannot read $MARKERS"; return 1; }
    if [ -n "$lines" ]; then
      [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 1 ] || { WHY="more than one line for it in $MARKERS"; return 1; }
      m=$(printf '%s\n' "$lines" | awk '{print $2 (NF > 2 ? " ?" : "")}')
      case "$m" in
        master|sparring|principal) MARK=$m MARK_WHY="named in seat-markers"; return 0;;
        inactive) MARK="" MARK_WHY="named inactive in seat-markers"; return 0;;
        *) WHY="its line in $MARKERS names '$m', and only master, sparring, principal and inactive are known"; return 1;;
      esac
    fi
  fi
  WHY="no recorded git marker: its snapshots record none, and $MARKERS has no line for it; a marker is never chosen here"
  return 1
}
marker_label() { if [ -n "$MARK" ]; then echo "marker $MARK, $MARK_WHY"; else echo "no marker, $MARK_WHY"; fi; }

panes_of() { "$TMUX_BIN" -L "$SOCKET" list-panes -s -t "=$1" -F '#{pane_id}|#{pane_pid}|#{@zeo_rescue}|#{pane_current_command}' 2>/dev/null; }
PANE="" PANE_PID="" PANE_STATE=""
find_pane() { # find_pane SESSION SID: sets PANE, PANE_PID and PANE_STATE (done, held, sleeping or none). A session can hold other windows.
  local id pid opt cmd
  PANE="" PANE_PID="" PANE_STATE=none
  while IFS='|' read -r id pid opt cmd; do
    if [ "$opt" = 1 ]; then PANE=$id PANE_PID=$pid PANE_STATE=done; return 0; fi
    case "$(ps_line "$pid")" in *"$2"*) PANE=$id PANE_PID=$pid PANE_STATE=held; return 0;; esac
    if [ "$cmd" = sleep ]; then PANE=$id PANE_PID=$pid PANE_STATE=sleeping; return 0; fi
  done < <(panes_of "$1")
}

SET_WHY=""
check_settings() { # check_settings PANE PID: sets SET_WHY unless the seat's settings are in its process and reach a shell that has no snapshot
  local want settings got acct proto ghdir f out
  SET_WHY=""
  want=$("$TMUX_BIN" -L "$SOCKET" show-options -pqv -t "$1" @zeo_seat 2>/dev/null); [ -n "$want" ] || want=inactive
  # The environment follows the arguments, and a prompt can hold text that looks like a setting, so a name's last appearance wins.
  # Only these four names are kept: a credential in the seat's environment never leaves this pipe.
  settings=$("$PS_BIN" -Ewwp "$2" -o command= 2>/dev/null | tr ' ' '\n' | grep -E '^(ZEO_TMUX_SEAT|ZEO_TMUX_ACCOUNT|GIT_ALLOW_PROTOCOL|GH_CONFIG_DIR)=')
  got=$(printf '%s\n' "$settings" | sed -n 's/^ZEO_TMUX_SEAT=//p' | tail -1)
  acct=$(printf '%s\n' "$settings" | sed -n 's/^ZEO_TMUX_ACCOUNT=//p' | tail -1)
  proto=$(printf '%s\n' "$settings" | sed -n 's/^GIT_ALLOW_PROTOCOL=//p' | tail -1)
  ghdir=$(printf '%s\n' "$settings" | sed -n 's/^GH_CONFIG_DIR=//p' | tail -1)
  if [ -z "$got" ]; then SET_WHY="process has no seat settings, so tools outside its folder miss them"; return 0; fi
  if [ "$got" != "$want" ]; then SET_WHY="process says $got, pane says $want"; return 0; fi
  # What a tool shell without the snapshot gets. Real git refuses before connecting, and ssh is /usr/bin/false, so this enters no seat and reaches nothing.
  for f in -lc -c; do
    out=$(cd / && /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin ZEO_TMUX_SEAT="$got" ${acct:+ZEO_TMUX_ACCOUNT="$acct"} ${proto:+GIT_ALLOW_PROTOCOL="$proto"} ${ghdir:+GH_CONFIG_DIR="$ghdir"} \
      GIT_SSH_COMMAND=/usr/bin/false GIT_TERMINAL_PROMPT=0 "$ZSH_BIN" "$f" 'print -r -- "gh=${GH_CONFIG_DIR##*/} author=${GIT_AUTHOR_EMAIL:-none}"; git ls-remote ssh://127.0.0.1/x 2>&1' 2>&1)
    case "$want:$out" in
      inactive:*"not allowed"*) case "$out" in *gh=disabled*) ;; *) SET_WHY="a shell outside its folder has gh on"; return 0;; esac;;
      inactive:*) SET_WHY="a shell outside its folder has git on"; return 0;;
      *"not allowed"*) SET_WHY="a shell outside its folder has git off"; return 0;;
      *author=none*) SET_WHY="a shell outside its folder has no seat author"; return 0;;
    esac
  done
}

moved_already() { # moved_already HARNESS PID SID: Codex says so on its command line. A Claude process follows a folder that moved under it, so its project says.
  if [ "$1" = codex ]; then case "$(ps_line "$2")" in *" -C $cwd "*) return 0;; esac; return 1; fi
  [ -f "$PROJECTS/$(project_key "$cwd")/$3.jsonl" ]
}

check_seat() { # check_seat SEAT SESSION HARNESS: prints OK or WRONG with the reason
  local id pid opt cmd line env snap why="" sid
  IFS='|' read -r id pid opt cmd < <(panes_of "$2")
  [ "$opt" = 1 ] || why="not started by rescue"
  # Nobody may type into a seat's terminal, so a seat stopped at a harness question waits for the operator. It is not resumed.
  if "$TMUX_BIN" -L "$SOCKET" capture-pane -p -t "$id" 2>/dev/null | grep -E 'Yes, I trust this folder|Do you trust the files|Trust this folder\?' >/dev/null; then
    why="${why:+$why; }waiting at the trust prompt: the operator must answer it"
  fi
  if [ "$3" = codex ]; then
    line=$(ps_line "$pid")
    case "$line" in *--no-daemon*) ;; *) why="${why:+$why; }no --no-daemon";; esac
    sid=$(printf '%s\n' "$line" | grep -o -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    snap=$(ls -t "$SNAPSHOTS/$sid".* 2>/dev/null | head -1)
    if [ -z "$snap" ]; then why="${why:+$why; }no snapshot"
    else grep -q "^export ZMAIL_INSTANCE=.\{0,1\}$1.\{0,1\}\$" "$snap" || why="${why:+$why; }snapshot has another identity"; fi
  else
    line=$(ps_line "$pid"); sid=$(printf '%s\n' "$line" | grep -o -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    env=$("$PS_BIN" -Ewwp "$pid" -o command= 2>/dev/null)
    case "$env" in *"ZMAIL_INSTANCE=$1 "*|*"ZMAIL_INSTANCE=$1") ;; *) why="${why:+$why; }environment has another identity";; esac
  fi
  if [ -n "$OLD_CWD" ] && ! moved_already "$3" "$pid" "$sid"; then why="${why:+$why; }not yet in its new folder $cwd"; fi
  check_settings "$id" "$pid"; [ -z "$SET_WHY" ] || why="${why:+$why; }$SET_WHY"
  if [ -z "$why" ]; then echo "OK $1 ($3)"; return 0; fi
  echo "WRONG $1 ($3): $why"; return 1
}

prove_codex() { # the first Codex seat must show the loader worked before any other starts
  local seat=$1 sid=$2 mark=$3 pf=$4 sess=$5 i snap="" id pid opt cmd
  for ((i = 0; i < PROOF_TRIES; i++)); do
    snap=$(find "$SNAPSHOTS" -name "$sid.*" -newer "$pf" 2>/dev/null | head -1)
    # a snapshot exists before it is written, so judge it only once it holds an identity
    if [ -n "$snap" ] && grep -q '^export ZMAIL_INSTANCE=' "$snap"; then break; fi
    pause "$PROOF_PAUSE"
  done
  [ -n "$snap" ] || { echo "STOPPED: no shell snapshot for $seat; no other seat was started"; return 1; }
  grep -q "^export ZMAIL_INSTANCE=.\{0,1\}$seat.\{0,1\}\$" "$snap" || { echo "STOPPED: $seat did not get its own identity; no other seat was started"; return 1; }
  if [ -n "$mark" ]; then
    grep -q "^export ZEO_TMUX_SEAT=.\{0,1\}$mark.\{0,1\}\$" "$snap" || { echo "STOPPED: $seat lacks marker $mark; no other seat was started"; return 1; }
    if grep -q '^export GIT_ALLOW_PROTOCOL=.\{0,1\}file.\{0,1\}$' "$snap"; then echo "STOPPED: $seat still has network git off; no other seat was started"; return 1; fi
  fi
  # A right snapshot speaks only for tools in the thread's own directory, so the process must have the settings too.
  IFS='|' read -r id pid opt cmd < <(panes_of "$sess")
  check_settings "$id" "$pid"
  [ -z "$SET_WHY" ] || { echo "STOPPED: $seat: $SET_WHY; no other seat was started"; return 1; }
  echo "FIRST SEAT OK $seat: own identity${mark:+, marker $mark, git on}"
}
prove_claude() { # the same for the first Claude seat, from the environment of the running process
  local seat=$1 mark=$2 sess=$3 i id pid opt cmd env=""
  for ((i = 0; i < PROOF_TRIES; i++)); do
    IFS='|' read -r id pid opt cmd < <(panes_of "$sess")
    env=$("$PS_BIN" -Ewwp "$pid" -o command= 2>/dev/null)
    case "$env" in *"ZMAIL_INSTANCE=$seat"*) break;; esac
    pause "$PROOF_PAUSE"
  done
  case "$env" in *"ZMAIL_INSTANCE=$seat "*|*"ZMAIL_INSTANCE=$seat") ;; *) echo "STOPPED: $seat did not get its own identity; no other seat was started"; return 1;; esac
  if [ -n "$mark" ]; then
    case "$env" in *"ZEO_TMUX_SEAT=$mark"*) ;; *) echo "STOPPED: $seat lacks marker $mark; no other seat was started"; return 1;; esac
    case "$env" in *"GIT_ALLOW_PROTOCOL=file "*) echo "STOPPED: $seat still has network git off; no other seat was started"; return 1;; esac
  fi
  echo "FIRST SEAT OK $seat: own identity${mark:+, marker $mark, git on}"
}

prove_claude_moved() { # prove_claude_moved SEAT SID FOLDER OLD SESSION SIZE PROMPT: one transcript, written from the new folder, by one process
  local seat=$1 sid=$2 to=$3 old=$4 sess=$5 size=$6 pf=$7 dir f i n found="" id pid opt cmd holders mapped
  dir=$PROJECTS/$(project_key "$to"); f=$dir/$sid.jsonl
  # only bytes written since the launch count, so a rerun cannot pass on an earlier record
  for ((i = 0; i < PROOF_TRIES; i++)); do
    if tail -c +$((size + 1)) "$f" 2>/dev/null | grep -F "\"cwd\":\"$to\"" >/dev/null; then found=1; break; fi
    pause "$PROOF_PAUSE"
  done
  [ -n "$found" ] || { echo "STOPPED: $seat: its transcript took no line from $to; no other seat was started"; return 1; }
  n=$(find "$PROJECTS" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 1 ] || { echo "STOPPED: $seat: $n transcripts carry session $sid; no other seat was started"; return 1; }
  n=$(find "$dir" -maxdepth 1 -name '*.jsonl' -newer "$pf" ! -name "$sid.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 0 ] || { echo "STOPPED: $seat: $n new sessions appeared beside its own; no other seat was started"; return 1; }
  [ ! -e "$PROJECTS/$(project_key "$old")" ] || { echo "STOPPED: $seat: its old project came back; no other seat was started"; return 1; }
  IFS='|' read -r id pid opt cmd < <(panes_of "$sess")
  holders=$("$PS_BIN" -axo pid=,command= | awk -v id="$sid" '($2 ~ /(^|\/)claude$/ || $2 ~ /\/claude\/versions\//) && index($0, id) {print $1}' | paste -sd' ' -)
  [ "$holders" = "$pid" ] || { echo "STOPPED: $seat: session $sid is held by pids '${holders}', not only by pid $pid; no other seat was started"; return 1; }
  mapped=$("$JQ" -r '.sessionId // empty' "$(dirname "$PROJECTS")/sessions/$pid.json" 2>/dev/null)
  [ -z "$mapped" ] || [ "$mapped" = "$sid" ] || { echo "STOPPED: $seat: its process says session $mapped; no other seat was started"; return 1; }
  echo "MOVED OK $seat: session $sid, one transcript, one process, in $to"
}

move_project() { # move_project OLD NEW SID: the seat's whole project goes by one rename while it is stopped: every session and its memory. Sets WHY.
  local from=$PROJECTS/$(project_key "$1") to=$PROJECTS/$(project_key "$2") size
  [ ! -f "$to/$3.jsonl" ] || return 0 # an earlier run did it
  [ -f "$from/$3.jsonl" ] || { WHY="no transcript at $from"; return 1; }
  [ ! -e "$to" ] || { WHY="$to already exists, and two projects are not merged here"; return 1; }
  holds "$3"; case $? in 1) ;; 0) WHY="a process still holds session $3"; return 1;; *) WHY="the process list could not be read, so session $3 may still be held"; return 1;; esac
  size=$(stat -f %z "$from/$3.jsonl")
  mv "$from" "$to" || { WHY="could not rename $from"; return 1; }
  [ "$(stat -f %z "$to/$3.jsonl" 2>/dev/null)" = "$size" ] || { WHY="its transcript changed in the rename"; return 1; }
}

db_read() { # db_read SQL: Codex keeps rows in its database's -wal for minutes, so an immutable read misses them (the Architect, 9 Nov 11:28Z).
  # It is read on a private copy of the database and its -wal, taken again until neither file changed while it was copied. The -shm is not
  # copied: it is only the -wal's index, sqlite rebuilds it from the copied -wal, and one copied a moment apart could name frames the copy lacks.
  local d i before r rc
  d=$(mktemp -d "${TMPDIR:-/tmp}/zeo-codex-db.XXXXXX") || return 1
  for ((i = 0; i < 5; i++)); do
    before=$(db_stamp)
    rm -f "$d/db" "$d/db-wal" "$d/db-shm"
    cp "$CODEX_DB" "$d/db" 2>/dev/null || break
    if [ -e "$CODEX_DB-wal" ]; then cp "$CODEX_DB-wal" "$d/db-wal" 2>/dev/null || break; fi
    [ "$(db_stamp)" = "$before" ] || continue
    r=$("$SQLITE" "$d/db" "$1" 2>/dev/null); rc=$?
    rm -f "$d/db" "$d/db-wal" "$d/db-shm"; rmdir "$d"
    [ $rc -eq 0 ] || return 1
    printf '%s\n' "$r"; return 0
  done
  rm -f "$d/db" "$d/db-wal" "$d/db-shm"; rmdir "$d"; return 1
}
db_stamp() { stat -f '%i %Fm %z' "$CODEX_DB" "$CODEX_DB-wal" 2>/dev/null; }
prove_moved() { # prove_moved SEAT SID ROLLOUT FOLDER SESSION SINCE: after a folder change the seat is still one thread, one rollout and one writer
  local seat=$1 sid=$2 roll=$3 to=$4 sess=$5 since=$6 i n=0 found="" others was id pid opt cmd who
  for ((i = 0; i < PROOF_TRIES; i++)); do
    if tail -c 2000000 "$roll" 2>/dev/null | grep -F "\"cwd\":\"$to\"" >/dev/null; then found=1; break; fi
    pause "$PROOF_PAUSE"
  done
  [ -n "$found" ] || { echo "STOPPED: $seat: its thread never recorded $to; no other seat was started"; return 1; }
  n=$(find "$SESSIONS" -name "*$sid*" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 1 ] || { echo "STOPPED: $seat: $n rollouts carry thread $sid; no other seat was started"; return 1; }
  others=$(db_read "select count(*) from threads where cwd = '$(printf %s "$to" | sed "s/'/''/g")' and id <> '$sid' and thread_source = 'user' and created_at >= $since;")
  [ "$others" = 0 ] || { echo "STOPPED: $seat: ${others:-an unknown number of} new threads appeared in $to; no other seat was started"; return 1; }
  IFS='|' read -r id pid opt cmd < <(panes_of "$sess")
  for ((i = 0; i < PROOF_TRIES; i++)); do # the rollout may not be open yet when the proof gets here, so one empty answer proves nothing
    if lsof_q -t -- "$roll"; then who=$(printf '%s\n' "$LSOF_OUT" | paste -sd' ' -); else who="unknown: $LSOF_ERR"; fi
    [ "$who" != "$pid" ] || break
    pause "$PROOF_PAUSE"
  done
  [ "$who" = "$pid" ] || { echo "STOPPED: $seat: its rollout is held by pids '${who}', not only by pid $pid; no other seat was started"; return 1; }
  was=$(db_read "select cwd from threads where id = '$sid';")
  [ "$was" = "$to" ] || echo "NOTE $seat: Codex's thread record still says ${was:-nothing}; session-pins holds the thread either way"
  echo "MOVED OK $seat: thread $sid, one rollout, one writer, in $to"
}

folder_ready() { # folder_ready SEAT TO: sets WHY unless the seat may move there. Only git folders ask for trust: Codex prompts when a project has no entry.
  local seat=$1 to=$2 how
  [[ "$to" = /* ]] && [ -d "$to" ] || { WHY="new folder $to does not exist"; return 1; }
  if printf '%s\n' "$rows" | cut -d$'\x1f' -f5 | grep -xF "$to" >/dev/null; then WHY="new folder $to is already a seat's folder in the chart"; return 1; fi
  if [ "$(awk -v t="$to" '$2==t' "$MOVES" | wc -l | tr -d ' ')" != 1 ]; then WHY="two seats would move to $to"; return 1; fi
  if [ "$harness" = claude ]; then # Claude asks in any folder, and its trust is keyed to the exact project root
    if [ "$(git -C "$to" rev-parse --absolute-git-dir 2>/dev/null)" != "$(git -C "$to" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then WHY="$to is a git worktree, and no Claude move into one is proved"; return 1; fi
    if [ -d "$PROJECTS/$(project_key "$to")" ] && [ -d "$PROJECTS/$(project_key "$cwd")" ]; then WHY="it has projects under both folders"; return 1; fi
    [ "$("$JQ" -r --arg d "$to" '.projects[$d].hasTrustDialogAccepted // false' "$CLAUDE_JSON" 2>/dev/null)" = true ] || { WHY="$to has no trusted entry in $CLAUDE_JSON, so Claude would stop at a question nobody may answer"; return 1; }
    return 0
  fi
  git -C "$to" rev-parse --git-dir >/dev/null 2>&1 || return 0
  how=$(awk -v p="[projects.\"$to\"]" '$0==p {f=1; next} f && /^\[/ {exit} f && /^trust_level *=/ {print; exit}' "$CODEX_CONFIG" 2>/dev/null)
  case "$how" in *'"trusted"'*) return 0;; esac
  WHY="$to is in git and has no trusted entry in $CODEX_CONFIG, so Codex would stop at a question nobody may answer"; return 1
}

CARRY="" CARRY_INO="" CARRY_BAD="" CARRY_REPOS=""
tree_of() { # tree_of PID: that process and every descendant, each followed by a space
  "$PS_BIN" -axo pid=,ppid= 2>/dev/null | awk -v r="$1" '{p[$1]=$2} END {for (c in p) {x=c; n=0; while (x != "" && x != r && n < 64) {x=p[x]; n++}; if (x == r) printf "%s ", c}}'
}
LSOF_OUT="" LSOF_ERR=""
lsof_q() { # lsof_q ARGS...: runs lsof and keeps what it said. Sets LSOF_OUT; 0 an answer (a match, or lsof's clean no-match: exit 1, nothing
  # on either stream), 2 the query failed (no lsof, another exit, or anything on stderr), with LSOF_ERR. An unread answer is never "nobody".
  local e rc
  LSOF_OUT="" LSOF_ERR=""
  [ -x "$LSOF" ] || { LSOF_ERR="no lsof at $LSOF"; return 2; }
  e=$(mktemp "${TMPDIR:-/tmp}/zeo-lsof.XXXXXX") || { LSOF_ERR="could not make a file for lsof's errors"; return 2; }
  LSOF_OUT=$("$LSOF" "$@" 2>"$e"); rc=$?
  LSOF_ERR=$(head -c 300 "$e" | tr '\n' ' '); rm -f "$e"
  if [ $rc -gt 1 ] || [ -n "$LSOF_ERR" ] || { [ $rc -eq 1 ] && [ -n "$LSOF_OUT" ]; }; then
    LSOF_ERR="lsof exited $rc${LSOF_ERR:+: $LSOF_ERR}"; LSOF_OUT=""; return 2
  fi
  return 0
}
UNDER=""
cwd_under() { # cwd_under DIR: sets UNDER, the pids whose working folder is DIR or inside it; 2, with LSOF_ERR, when that could not be read
  UNDER=""
  lsof_q -a -d cwd -Fpn || return 2
  UNDER=$(printf '%s\n' "$LSOF_OUT" | awk -v d="$1" '/^p/ {p=substr($0,2)} /^n/ {n=substr($0,2); if (n==d || index(n, d "/")==1) print p}' | sort -u | paste -sd' ' -)
}
rpath() { if [ "$2" = . ]; then printf %s "$1"; else printf %s "$1/$2"; fi; } # rpath FOLDER REL: a clone's path in the carried folder
carry_repos() { # carry_repos FROM KIND: sets CARRY_REPOS, the clones a carry moves, one per line ("." is FROM itself), or WHY. Reads only.
  local from=$1 kind=$2 gl g r
  CARRY_REPOS=""
  if [ "$kind" = carry ]; then
    [ "$(git -C "$from" rev-parse --show-toplevel 2>/dev/null)" = "$from" ] || { WHY="$from is not the top of a git clone"; return 1; }
    [ "$(git -C "$from" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$from/.git" ] || { WHY="$from is not an ordinary clone with its own .git, so it is not carried"; return 1; }
    CARRY_REPOS=.; return 0
  fi
  ! git -C "$from" rev-parse --git-dir >/dev/null 2>&1 || { WHY="$from is in git, and only a folder outside git is carried plain"; return 1; }
  gl=$(find "$from" -name .git -prune -print 2>/dev/null) || { WHY="cannot read every folder in $from, so its clones are not known"; return 1; }
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    r=${g%/.git}; r=${r#"$from"/}
    [ -d "$g" ] && [ ! -L "$g" ] || { WHY="$g is not a .git folder: a linked worktree or submodule, which a plain carry would break"; return 1; }
    [ "$(git -C "$from/$r" rev-parse --show-toplevel 2>/dev/null)" = "$from/$r" ] && [ "$(git -C "$from/$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$from/$r/.git" ] \
      || { WHY="$from/$r is not an ordinary clone with its own .git, so it is not carried"; return 1; }
    CARRY_REPOS=$CARRY_REPOS$r$'\n'
  done <<< "$gl"
  CARRY_REPOS=$(printf %s "$CARRY_REPOS" | LC_ALL=C sort)
}
carry_ready() { # carry_ready FROM TO [KIND]: sets WHY unless the seat's folder may be carried to TO while it is stopped: its own clone (carry),
  # or a plain folder of clones (carry-plain). Sets CARRY_INO and CARRY_REPOS. Reads only.
  local from=$1 to=$2 kind=${3:-carry} up anc w h r p
  CARRY_INO=""
  [[ "$from" = /* ]] && [[ "$to" = /* ]] || { WHY="a carry needs absolute folders"; return 1; }
  [ -d "$from" ] && [ ! -L "$from" ] || { WHY="$from is not a folder"; return 1; }
  carry_repos "$from" "$kind" || return 1
  [ ! -e "$to" ] && [ ! -L "$to" ] || { WHY="$to already exists"; return 1; }
  up=$(dirname "$to") anc=$from
  case "$up" in
    "$from") ;; # <repo> becomes <repo>/main: the clone steps down into a new folder of its old name
    "$from"/*) WHY="$to is more than one level inside $from"; return 1;;
    *) if [ -e "$up" ] || [ -L "$up" ]; then anc=$up; [ -d "$up" ] && [ ! -L "$up" ] || { WHY="$up is not a folder"; return 1; }
       else anc=$(dirname "$up"); [ -d "$anc" ] && [ ! -L "$anc" ] || { WHY="neither $up nor its parent is a folder"; return 1; }; fi
       ! git -C "$anc" rev-parse --git-dir >/dev/null 2>&1 || { WHY="$anc is in git, so $to would be inside a repository"; return 1; };;
  esac
  [ "$(stat -f %d "$anc")" = "$(stat -f %d "$from")" ] || { WHY="$to is on another volume, so the move would be a copy"; return 1; }
  while IFS= read -r r; do
    [ -n "$r" ] || continue; p=$(rpath "$from" "$r")
    while IFS= read -r w; do
      case "$w" in "$from"/*) WHY="its linked worktree $w is inside it, and a carry repairs only worktrees outside"; return 1;; esac
    done < <(git -C "$p" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
    w=$(git -C "$p" config --list 2>/dev/null | grep -F -- "$from" | head -1)
    [ -z "$w" ] || { WHY="its git config names its own path ($w), which the carry would break"; return 1; }
  done <<< "$CARRY_REPOS"
  if [ "$harness" = claude ]; then
    [ "$("$JQ" -r --arg d "$to" '.projects[$d].hasTrustDialogAccepted // false' "$CLAUDE_JSON" 2>/dev/null)" = true ] || { WHY="$to has no trusted entry in $CLAUDE_JSON, so Claude would stop at a question nobody may answer"; return 1; }
    [ ! -e "$PROJECTS/$(project_key "$to")" ] || { WHY="$PROJECTS/$(project_key "$to") already exists, and two projects are not merged here"; return 1; }
  else
    h=$(awk -v p="[projects.\"$to\"]" '$0==p {f=1; next} f && /^\[/ {exit} f && /^trust_level *=/ {print; exit}' "$CODEX_CONFIG" 2>/dev/null)
    case "$h" in *'"trusted"'*) ;; *) WHY="$to has no trusted entry in $CODEX_CONFIG, so Codex would stop at a question nobody may answer"; return 1;; esac
  fi
  CARRY_INO=$(stat -f %i "$from")
}
carry_folder() { # carry_folder INDEX: with the seat stopped, the clone goes to its new path by rename, then its linked worktrees are repaired. Sets WHY.
  local i=$1 from=${P_OLD[$1]} to=${P_CWD[$1]} ino=${P_INO[$1]} kind=${P_CARRY[$1]} head="" w n=0 left="" up tmp made="" k wbad="" r p rh="" rw="" h ok
  [ "$(stat -f %i "$from" 2>/dev/null)" = "$ino" ] || { WHY="$from is not the folder the plan read (inode $ino); nothing was moved"; return 1; }
  [ ! -e "$to" ] && [ ! -L "$to" ] || { WHY="$to appeared after the plan; nothing was moved"; return 1; }
  for ((k = 0; k < STOP_TRIES; k++)); do
    cwd_under "$from" || { WHY="which processes work in $from cannot be read ($LSOF_ERR); nothing was moved"; return 1; }
    left=$UNDER; [ -n "$left" ] || break; pause 1
  done
  [ -z "$left" ] || { WHY="pid $left still works in $from after the stop; nothing was moved"; return 1; }
  carry_repos "$from" "$kind" || { WHY="$WHY; nothing was moved"; return 1; }
  [ "$CARRY_REPOS" = "${P_REPOS[$i]}" ] || { WHY="the clones in $from are not the ones the plan read; nothing was moved"; return 1; }
  # Each clone's commit before, and its linked worktrees elsewhere that are live: REL TAB HEAD, and REL TAB WORKTREE.
  while IFS= read -r r; do
    [ -n "$r" ] || continue; p=$(rpath "$from" "$r")
    rh=$rh$r$'\t'$(git -C "$p" rev-parse HEAD 2>/dev/null)$'\n'
    while IFS= read -r w; do [ -z "$w" ] || [ ! -e "$w/.git" ] || { rw=$rw$r$'\t'$w$'\n'; n=$((n+1)); }; done < <(git -C "$p" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
  done <<< "$CARRY_REPOS"
  [ "$kind" != carry ] || head=$(git -C "$from" rev-parse HEAD 2>/dev/null)
  up=$(dirname "$to")
  if [ "$up" = "$from" ]; then
    tmp=$from.carry-${P_SEAT[$i]}
    [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || { WHY="$tmp is in the way; nothing was moved"; return 1; }
    mv "$from" "$tmp" || { WHY="could not rename $from; nothing was moved"; return 1; }
    if ! mkdir -m 755 "$from"; then
      if mv "$tmp" "$from"; then WHY="could not make $from again; the clone was put back"; else WHY="could not make $from again, and the clone is at $tmp"; fi; return 1; fi
    if ! mv "$tmp" "$to"; then
      if rmdir "$from" && mv "$tmp" "$from"; then WHY="could not move the clone into $from; it was put back"; else WHY="could not move the clone into $from, and it is at $tmp"; fi; return 1; fi
  else
    if [ ! -d "$up" ]; then mkdir -m 755 "$up" || { WHY="could not make $up; nothing was moved"; return 1; }; made=1; fi
    if ! mv "$from" "$to"; then [ -z "$made" ] || rmdir "$up"; WHY="could not move $from to $to; nothing was moved"; return 1; fi
  fi
  ok=1; [ "$(stat -f %i "$to" 2>/dev/null)" = "$ino" ] || ok=""
  while IFS=$'\t' read -r r h; do
    [ -n "$r" ] || continue; p=$(rpath "$to" "$r")
    [ "$(git -C "$p" rev-parse --show-toplevel 2>/dev/null)" = "$p" ] && [ "$(git -C "$p" rev-parse HEAD 2>/dev/null)" = "$h" ] || ok=""
  done <<< "$rh"
  [ -n "$ok" ] || { if [ "$kind" = carry ]; then WHY="$to does not read as the same clone after the move"; else WHY="$to does not read as the same folder with the same clones after the move"; fi; return 1; }
  while IFS=$'\t' read -r r w; do
    [ -n "$r" ] || continue; p=$(rpath "$to" "$r")
    git -C "$p" worktree repair "$w" >/dev/null 2>&1
    [ "$(git -C "$w" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$p/.git" ] || wbad="$wbad $w"
  done <<< "$rw"
  if [ "$kind" = carry ]; then
    echo "CARRIED ${P_SEAT[$i]}: $from to $to, the same folder (inode $ino) at ${head:-no commit}; $n linked worktrees elsewhere repaired${wbad:+, but these still do not reach it:$wbad}"
  else
    echo "CARRIED ${P_SEAT[$i]}: $from to $to, the same plain folder (inode $ino) with its $(printf %s "$CARRY_REPOS" | grep -c .) clones, each at the same commit; $n linked worktrees elsewhere repaired${wbad:+, but these still do not reach it:$wbad}"
  fi
  [ -z "$wbad" ] || CARRY_BAD="$CARRY_BAD ${P_SEAT[$i]}"
  return 0
}

HOLDER="" HOLD_WHY=""
rollout_free() { # rollout_free FILE: fails while any process has the rollout open, or while that cannot be read. Run it after the daemon stop.
  # Sets HOLDER (the pids) and HOLD_WHY. Only lsof's own clean no-match frees a rollout: an error with no output is not "nobody".
  local i
  HOLDER="" HOLD_WHY=""
  for ((i = 0; i < STOP_TRIES; i++)); do
    lsof_q -t -- "$1" || { HOLD_WHY="who holds its rollout cannot be read ($LSOF_ERR)"; return 1; }
    HOLDER=$(printf '%s\n' "$LSOF_OUT" | paste -sd' ' -)
    [ -n "$HOLDER" ] || return 0
    pause 1
  done
  HOLD_WHY="pid $HOLDER still holds its rollout"
  return 1
}

children() { # children TREE PID: a process's children as "pid etime command", without what every seat runs: mail hooks, caffeinate and the daemon's own processes
  printf '%s\n' "$1" | awk -v p="$2" '$2==p { c=$0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", c); i=index(c, " && eval "); if (i) c=substr(c, i+9)
    if (c !~ /\/\.local\/share\/zeo\/messenger\/hooks\// && c !~ /^caffeinate / && c !~ /\/app-server-daemon\/releases\// && c !~ /\/codex-code-mode-host$/) print $1, $3, substr(c, 1, 110) }'
}
work_list() { # what a restart would cut: it reads only, and a quiet result is what could be seen, not a promise that nothing is in progress
  local tree i seats=0 busy=0 hit kids daemon line pid
  tree=$("$PS_BIN" -axo pid=,ppid=,etime=,command=) || { echo "WORK: ps failed, so running work is unknown"; return 0; }
  for ((i = 0; i < ${#P_SEAT[@]}; i++)); do
    [ -n "${P_PANE[$i]}" ] || continue
    seats=$((seats+1)) hit=0
    if "$TMUX_BIN" -L "$SOCKET" capture-pane -p -t "${P_PANE[$i]}" 2>/dev/null | grep 'esc to interrupt' >/dev/null; then echo "WORK ${P_SEAT[$i]}: a turn is in progress on its screen"; hit=1; fi
    kids=$(children "$tree" "${P_PID[$i]}")
    if [ -n "$kids" ]; then hit=1; while IFS= read -r line; do echo "WORK ${P_SEAT[$i]}: $line"; done <<< "$kids"; fi
    busy=$((busy+hit))
  done
  # Under the shared daemon a Codex seat's tools are children of the app-server, not of the seat's pane; the working directory says whose.
  daemon=$(printf '%s\n' "$tree" | awk '$4 ~ /\/app-server-daemon\/releases\// && /app-server --listen/ {print $1}' | head -1)
  if [ -n "$daemon" ]; then
    kids=$(children "$tree" "$daemon")
    if [ -n "$kids" ]; then
      while IFS= read -r line; do pid=${line%% *}; echo "WORK daemon, in $("$LSOF" -a -d cwd -Fn -p "$pid" 2>/dev/null | sed -n 's/^n//p' | head -1): $line"; done <<< "$kids"
    fi
  fi
  echo "work: $busy of $seats seats show running work"
}

unseat() { # unseat INDEX: a seat that failed must not stay up wrong, and must not keep the mark that makes the next run skip it
  local i=$1 pane=${P_PANE[$1]}
  if [ -n "$pane" ]; then
    "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$pane" -c "${P_CWD[$i]}" -- sleep 3600 2>/dev/null || echo "WARNING: could not stop ${P_SEAT[$i]}: stop it before anything else runs"
    "$TMUX_BIN" -L "$SOCKET" set-option -pu -t "$pane" @zeo_rescue 2>/dev/null
  elif [ -n "${P_CREATED[$i]:-}" ]; then # this run's own new-session made the session, so it goes, and a later run resumes the seat
    "$TMUX_BIN" -L "$SOCKET" kill-session -t "=${P_SESS[$i]}" 2>/dev/null
  fi # a session this run did not create is never killed: something else started it, and it is left alone
}

recovery() { # recovery FROM: after a run that stopped, say what is down and what brings it back
  local i left=0
  for ((i = $1; i < ${#P_SEAT[@]}; i++)); do [ -z "${P_SEAT[$i]}" ] || left=$((left+1)); done
  echo "RECOVERY: $left seats are down, counting the one that failed. Each thread is intact and nothing is lost. Start none of them by hand. Tell zeo-rescue what you see; once the cause is fixed, the same line brings them back, whether or not their sleep has run out."
}

stop_seat() { # stop_seat PANE CWD SID: replace the harness with a sleep, and wait until nothing holds the session
  local i
  "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$1" -c "$2" -- sleep 3600 || return 1
  for ((i = 0; i < STOP_TRIES; i++)); do holds "$3"; [ $? -ne 1 ] || return 0; pause 1; done
  return 1
}

stop_daemon() { # the shared app-server keeps every attached thread open, so it goes only when no seat is attached to it, and only when each
  # thread it holds open is a seat this run stopped (the Architect, 9 Nov 11:28Z). What it serves is read from the rollouts it has open;
  # when that cannot be read, no daemon is stopped, and the run says so.
  local out attached pids p held ids id ours="" i
  out=$("$PS_BIN" -axo pid=,command=) || { echo "DAEMON UNKNOWN: ps could not be read, so no daemon was stopped"; return 1; }
  attached=$(printf '%s\n' "$out" | grep -E '/codex resume ' | grep -vc -- '--no-daemon')
  pids=$(printf '%s\n' "$out" | awk '$2 ~ /\/app-server-daemon\/releases\// {print $1}' | paste -sd' ' -)
  [ -n "$pids" ] || return 0
  if [ "$attached" -gt 0 ]; then echo "DAEMON LEFT: $attached Codex seats are still attached to pids $pids"; return 0; fi
  [ -x "$LSOF" ] || { echo "DAEMON LEFT: which seats pids $pids serve cannot be read (no lsof), so no daemon was stopped"; return 0; }
  for ((i = 0; i < ${#P_SEAT[@]}; i++)); do [ -z "${P_SEAT[$i]}" ] || ours="$ours ${P_SID[$i]}"; done; ours="$ours "
  for p in $pids; do
    held=$("$LSOF" -Fn -p "$p" 2>/dev/null) && [ -n "$held" ] || { echo "DAEMON LEFT: which seats pid $p serves cannot be read, so no daemon was stopped"; return 0; }
    ids=$(printf '%s\n' "$held" | sed -n 's/^n//p' | grep -E '\.jsonl$' | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' | sed 's/\.jsonl$//' | sort -u)
    for id in $ids; do
      case "$ours" in *" $id "*) ;; *) echo "DAEMON LEFT: pid $p holds thread $id open, which is no seat this run stopped, so no daemon was stopped"; return 0;; esac
    done
  done
  for p in $pids; do echo "DAEMON STOP: pid $p, $(printf '%s\n' "$out" | awk -v p="$p" '$1==p {$1=""; print substr($0, 2); exit}' | cut -c1-120)"; done
  # shellcheck disable=SC2086  # pids holds only numbers from ps
  "$KILL_BIN" $pids 2>/dev/null
  pause "${ZEO_RESCUE_DAEMON_WAIT:-5}"
  for p in $pids; do
    if "$PS_BIN" -axo pid=,command= | awk -v p="$p" '$1==p {f=1} END {exit !f}'; then "$KILL_BIN" -9 "$p" 2>/dev/null; echo "DAEMON KILLED: pid $p ignored SIGTERM"; fi
  done
}

still_free() { # still_free INDEX: the plan read every seat at the start of the run, and with the stagger a late seat starts minutes after
  # that. So just before its start this reads it again, and sets WHY if it is no longer the seat the plan saw: a process now holds its
  # session, or, for a seat that was down, its session or a harness process in its folder appeared. A check that cannot be read stops too.
  local i=$1 rc
  holds "${P_SID[$i]}"; rc=$?
  [ $rc -ne 0 ] || { WHY="a process holds its session ${P_SID[$i]} now, which the plan did not see; it is left alone"; return 1; }
  [ $rc -eq 1 ] || { WHY="the process list cannot be read just before the start"; return 1; }
  [ -z "${P_PANE[$i]}" ] || return 0
  ! "$TMUX_BIN" -L "$SOCKET" has-session -t "=${P_SESS[$i]}" 2>/dev/null || { WHY="its session ${P_SESS[$i]} appeared after the plan: something else started it, and it is left alone"; return 1; }
  PSOUT=$("$PS_BIN" -axo pid=,command=) || { WHY="the process list cannot be read just before the start"; return 1; }
  running_in "${P_HARNESS[$i]}" "${P_CWD[$i]}"; rc=$?
  [ $rc -ne 0 ] || { WHY="a ${P_HARNESS[$i]} process runs in ${P_CWD[$i]} now, which the plan did not see; it is left alone"; return 1; }
  [ $rc -eq 1 ] || { WHY="whether a process runs in ${P_CWD[$i]} cannot be read just before the start ($RUN_ERR)"; return 1; }
}
launch() { # launch INDEX: the marker goes on before any shell starts
  local i=$1 seat=${P_SEAT[$1]} sess=${P_SESS[$1]} cwd=${P_CWD[$1]} harness=${P_HARNESS[$1]} sid=${P_SID[$1]} mark=${P_MARK[$1]} pane=${P_PANE[$1]} pf
  pf=$STATE/prompts/$seat.txt
  local cur=CUR_$harness
  { if [ $UPGRADE -eq 1 ] && [ -n "$pane" ]; then printf "%s" "${UPROMPT/\%s/${!cur}}"; else printf '%s' "$PROMPT"; fi
    if [ -n "$NOTE_FILE" ]; then printf ' '; cat "$NOTE_FILE"; fi
    if [ -n "${P_OLD[$i]}" ]; then printf ' Your working folder moved from %s to %s by the Architect'"'"'s order. This is the same thread, with your history. Work in the new folder from now on.' "${P_OLD[$i]}" "$cwd"; fi; } > "$pf" || return 1
  LAUNCH_WHY="tmux could not start it"
  if [ -z "$pane" ]; then
    if ! env -u TMUX "$TMUX_BIN" -L "$SOCKET" new-session -d -s "$sess" -c "$cwd" -- sleep 3600; then
      ! "$TMUX_BIN" -L "$SOCKET" has-session -t "=$sess" 2>/dev/null || LAUNCH_WHY="its session $sess exists already: something else started it after the check, and it is left alone"
      return 1
    fi
    P_CREATED[$i]=1
    pane=$(panes_of "$sess" | head -1 | cut -d'|' -f1)
    [ -n "$pane" ] || return 1
  fi
  if [ -n "$mark" ]; then "$TMUX_BIN" -L "$SOCKET" set-option -p -t "$pane" @zeo_seat "$mark" || return 1
  else "$TMUX_BIN" -L "$SOCKET" set-option -pu -t "$pane" @zeo_seat 2>/dev/null; fi
  "$TMUX_BIN" -L "$SOCKET" set-option -p -t "$pane" @zeo_rescue 1 || return 1
  # shellcheck disable=SC2086  # the mode holds only words validated by plan_claude and plan_codex
  if [ "$harness" = claude ]; then
    "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$pane" -c "$cwd" -- "$HERE/seat-exec.sh" "$seat" claude "$pf" "$CLAUDE" --resume "$sid" ${P_MODE[$i]}
  else
    "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$pane" -c "$cwd" -- "$HERE/seat-exec.sh" "$seat" codex "$pf" "$CODEX" resume ${P_MODE[$i]} -C "$cwd" --no-daemon "$sid"
  fi
}

P_SEAT=() P_SESS=() P_CWD=() P_HARNESS=() P_SID=() P_MODE=() P_MARK=() P_PANE=() P_WHY=() P_ROLL=() P_PID=() P_OLD=() P_CARRY=() P_INO=() P_REPOS=()
live=0 ok=0 wrong=0 running=0 resume=0 resumed=0 reseat=0 unresolved=0 failed=0
planned() { # planned SEAT SESSION CWD HARNESS PANE: record what the plan decided
  local n=${#P_SEAT[@]}
  P_SEAT[$n]=$1 P_SESS[$n]=$2 P_CWD[$n]=$3 P_HARNESS[$n]=$4 P_SID[$n]=$SID P_MODE[$n]=$MODE_ARGS P_MARK[$n]=$MARK P_PANE[$n]=$5 P_WHY[$n]=$(marker_label) P_ROLL[$n]=$ROLL P_PID[$n]=$PANE_PID P_OLD[$n]=$OLD_CWD
  P_CARRY[$n]=$CARRY P_INO[$n]=$CARRY_INO P_REPOS[$n]=$CARRY_REPOS
  [ -z "$OLD_CWD" ] || echo "MOVE $1: from $OLD_CWD to $3${CARRY:+, carrying the $( [ "$CARRY" = carry-plain ] && echo "plain folder" || echo clone) while the seat is stopped}"
}
while IFS=$'\x1f' read -r seat mailbox harness sess cwd; do
  [ -n "$seat" ] || continue
  [ "$seat" != zeo-rescue ] || continue # the rescue seat is started by hand and never by itself
  [ "$HARNESS" = all ] || [ "$HARNESS" = "$harness" ] || continue
  [ "$ONLY" = " " ] || case "$ONLY" in *" $seat "*) ;; *) continue;; esac
  case "$EXCEPT" in *" $seat "*) echo "EXCEPT $seat: left out of this run"; continue;; esac
  if [ "$sess" = "-" ] || [ "$cwd" = "-" ]; then echo "UNRESOLVED $seat: the chart gives no session or folder"; unresolved=$((unresolved+1)); continue; fi
  [[ "$sess" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || { echo "UNRESOLVED $seat: bad session name $sess"; unresolved=$((unresolved+1)); continue; }
  [ "$mailbox" = "$seat" ] || { echo "UNRESOLVED $seat: mailbox is $mailbox, not the seat id; the identity map must say which it starts as"; unresolved=$((unresolved+1)); continue; }
  SID="" MODE_ARGS="" WHY="" SANDBOX="" ROLL="" MARK="" MARK_WHY="" PANE_PID=""
  SESSION=$SESSION_ARG
  if [ -z "$SESSION" ] && [ -f "$PINS" ]; then
    SESSION=$(awk -v s="$seat" '$1==s {print $2}' "$PINS")
    [ -z "$SESSION" ] || [[ "$SESSION" =~ $ID_RE ]] || { echo "UNRESOLVED $seat: bad pin in $PINS"; unresolved=$((unresolved+1)); continue; }
  fi
  OLD_CWD="" to="" how="" CARRY="" CARRY_INO="" CARRY_REPOS=""
  if [ -f "$MOVES" ]; then to=$(awk -v s="$seat" '$1==s {print $2}' "$MOVES"); how=$(awk -v s="$seat" '$1==s {print $3}' "$MOVES"); fi
  if [ $UPGRADE -eq 1 ]; then # an upgrade restarts a live seat in the folder its process works in now, and never moves, carries or resumes one
    "$TMUX_BIN" -L "$SOCKET" has-session -t "=$sess" 2>/dev/null || { echo "DOWN $seat: an upgrade restarts only live seats; a seat that is down is resumed by its own line"; unresolved=$((unresolved+1)); continue; }
    find_pane "$sess" zeo-rescue-upgrade-no-session
    if [ "$PANE_STATE" = done ]; then
      pc=$("$LSOF" -a -p "$PANE_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
      if [ -n "$to" ] && [ -n "$pc" ] && [ "$pc" = "$to" ]; then cwd=$to
      elif [ -z "$pc" ] || [ "$pc" != "$cwd" ]; then echo "UNRESOLVED $seat: pid $PANE_PID works in ${pc:-a folder lsof cannot read}, which is not its chart folder $cwd${to:+ nor the folder of its line, $to}, so an upgrade does not restart it"; unresolved=$((unresolved+1)); continue; fi
    fi
    to="" how=""
  fi
  if [ -n "$to" ] && [ "$to" != "$cwd" ]; then # once the chart itself says the new folder, the line has nothing left to do
    WHY=""
    if [ "$(awk -v s="$seat" '$1==s' "$MOVES" | wc -l | tr -d ' ')" != 1 ]; then WHY="more than one line for it in $MOVES"
    elif [ -n "$how" ] && [ "$how" != carry ] && [ "$how" != carry-plain ]; then WHY="its line in $MOVES ends in '$how', and only carry and carry-plain are known"
    elif [ -z "$SESSION" ]; then WHY="it moves folder, so $PINS must name its thread"
    elif [ -n "$how" ] && [ ! -e "$to" ] && [ ! -L "$to" ]; then carry_ready "$cwd" "$to" "$how" && CARRY=$how # once carried, it is an ordinary move
    elif [ "$how" = carry ] && { [ "$(git -C "$to" rev-parse --show-toplevel 2>/dev/null)" != "$to" ] || [ "$(git -C "$to" rev-parse --absolute-git-dir 2>/dev/null)" != "$to/.git" ]; }; then
      WHY="$to is there, but it is not a carried clone with its own .git"
    elif [ "$how" = carry-plain ] && { [ ! -d "$to" ] || [ -L "$to" ] || git -C "$to" rev-parse --git-dir >/dev/null 2>&1; }; then
      WHY="$to is there, but it is not a carried plain folder outside git"
    else folder_ready "$seat" "$to"; fi
    if [ -n "$WHY" ]; then
      if [ $CHECK -eq 1 ]; then echo "WRONG $seat ($harness): $WHY"; wrong=$((wrong+1)); else echo "UNRESOLVED $seat: $WHY"; unresolved=$((unresolved+1)); fi
      continue
    fi
    if [ -n "$CARRY" ] && [ $CHECK -eq 1 ]; then echo "WRONG $seat ($harness): not yet carried to $to; the carry is ready"; wrong=$((wrong+1)); continue; fi
    OLD_CWD=$cwd cwd=$to
  fi
  if "$TMUX_BIN" -L "$SOCKET" has-session -t "=$sess" 2>/dev/null; then
    if [ $CHECK -eq 1 ]; then if check_seat "$seat" "$sess" "$harness"; then ok=$((ok+1)); else wrong=$((wrong+1)); fi; continue; fi
    if [ $RESEAT -eq 0 ]; then echo "LIVE $seat ($sess)"; live=$((live+1)); continue; fi
    # tmux would start it somewhere else, and Claude would resume there; a folder moved under a live seat with no line in folder-moves is the case
    if [ -n "$CARRY" ]; then [ -d "$OLD_CWD" ] || { echo "UNRESOLVED $seat: no directory $OLD_CWD"; unresolved=$((unresolved+1)); continue; }
    else [ -d "$cwd" ] || { echo "UNRESOLVED $seat: no directory $cwd"; unresolved=$((unresolved+1)); continue; }; fi
    if ! "plan_$harness" "$cwd"; then echo "UNRESOLVED $seat: $WHY"; unresolved=$((unresolved+1)); continue; fi
    find_pane "$sess" "$SID"
    if [ -n "$CARRY" ] && [ -n "$PANE_PID" ]; then # anything else working in the clone would have its folder moved from under it
      WHY="" mine=" $(tree_of "$PANE_PID")"
      if ! cwd_under "$OLD_CWD"; then echo "UNRESOLVED $seat: which processes work in $OLD_CWD cannot be read ($LSOF_ERR), so it is not carried"; unresolved=$((unresolved+1)); continue; fi
      for p in $UNDER; do case "$mine" in *" $p "*) ;; *) WHY="pid $p works in $OLD_CWD and is not the seat's own, so the carry would move the folder from under it";; esac; done
      [ -z "$WHY" ] || { echo "UNRESOLVED $seat: $WHY"; unresolved=$((unresolved+1)); continue; }
    fi
    case "$PANE_STATE" in
      done)
        [ $RELAUNCH -eq 1 ] || { echo "OK $seat: started by rescue"; ok=$((ok+1)); continue; }
        case "$(ps_line "$PANE_PID")" in *"$SID"*) ;; *) echo "UNRESOLVED $seat: its pane does not hold $SID"; unresolved=$((unresolved+1)); continue;; esac
        check_settings "$PANE" "$PANE_PID"
        case "$SET_WHY" in ""|*"no seat settings"*) ;; *) echo "UNRESOLVED $seat: $SET_WHY; a restart would not change that"; unresolved=$((unresolved+1)); continue;; esac
        STALE=""
        if [ $UPGRADE -eq 1 ]; then
          cur=CUR_$harness; runs_binary "$PANE_PID" "${!cur}"; rc=$?
          [ $rc -le 1 ] || { echo "UNRESOLVED $seat: could not read which binary pid $PANE_PID runs, so it is not restarted for the upgrade"; unresolved=$((unresolved+1)); continue; }
          [ $rc -eq 0 ] || { STALE=1; echo "UPGRADE $seat: pid $PANE_PID runs $RUN_BIN; installed now is ${!cur}"; }
        fi
        if [ $RESTART -eq 0 ] && [ -z "$STALE" ] && [ -z "$SET_WHY" ] && { [ -z "$OLD_CWD" ] || moved_already "$harness" "$PANE_PID" "$SID"; }; then echo "OK $seat: started by rescue, right already"; ok=$((ok+1)); continue; fi;;
      none) echo "UNRESOLVED $seat: no pane in $sess holds $SID"; unresolved=$((unresolved+1)); continue;;
    esac
    if ! marker_of "$harness" "$SID" "$seat"; then echo "UNRESOLVED $seat: $WHY"; unresolved=$((unresolved+1)); continue; fi
    echo "RESEAT $seat: $harness $SID ($MODE_ARGS; $(marker_label)) in $sess"; reseat=$((reseat+1))
    planned "$seat" "$sess" "$cwd" "$harness" "$PANE"
    continue
  fi
  [ $CHECK -eq 0 ] || { echo "WRONG $seat ($harness): no session $sess"; wrong=$((wrong+1)); continue; }
  [ -z "$CARRY" ] || { echo "UNRESOLVED $seat: it is down, and a carry moves only a seat this run stops itself"; unresolved=$((unresolved+1)); continue; }
  running_in "$harness" "$cwd"; rc=$?
  [ $rc -eq 0 ] && { echo "RUNNING $seat: a $harness process is in $cwd"; running=$((running+1)); continue; }
  [ $rc -eq 2 ] && { echo "UNRESOLVED $seat: could not tell whether a process runs in $cwd ($RUN_ERR), so it is not started this run"; unresolved=$((unresolved+1)); continue; }
  [ -d "$cwd" ] || { echo "UNRESOLVED $seat: no directory $cwd"; unresolved=$((unresolved+1)); continue; }
  if ! "plan_$harness" "$cwd"; then echo "UNRESOLVED $seat: $WHY"; unresolved=$((unresolved+1)); continue; fi
  if ! marker_of "$harness" "$SID" "$seat"; then echo "UNRESOLVED $seat: $WHY"; unresolved=$((unresolved+1)); continue; fi
  echo "RESUME $seat: $harness $SID ($MODE_ARGS; $(marker_label)) in $sess"; resume=$((resume+1))
  planned "$seat" "$sess" "$cwd" "$harness" ""
done <<< "$rows"

if [ $CHECK -eq 1 ]; then
  echo "check: ok $ok, wrong $wrong"
  [ $wrong -eq 0 ] || exit 1
  exit 0
fi

stopped=1
[ $RESEAT -eq 0 ] || work_list
if [ $APPLY -eq 1 ]; then
  n=${#P_SEAT[@]}
  # Every harness is stopped first, then the daemon, and only then does any seat start: a thread must never have two writers.
  for ((i = 0; i < n; i++)); do
    [ -n "${P_PANE[$i]}" ] || continue
    sd=${P_CWD[$i]}; [ -z "${P_CARRY[$i]}" ] || sd=$(dirname "${P_OLD[$i]}") # a carry's new folder is not there yet, and its old one is about to go
    if ! stop_seat "${P_PANE[$i]}" "$sd" "${P_SID[$i]}"; then echo "FAILED ${P_SEAT[$i]}: its old process would not stop, so it was not restarted"; P_SEAT[$i]=""; failed=$((failed+1)); fi
  done
  [ $RESEAT -eq 0 ] || stop_daemon
  proved_codex=0 proved_claude=0
  for ((i = 0; i < n; i++)); do
    seat=${P_SEAT[$i]}; [ -n "$seat" ] || continue
    [ $resumed -eq 0 ] || [ "$STAGGER" -eq 0 ] || pause "$STAGGER" # first, so every check below is as fresh as the start
    if [ "${P_HARNESS[$i]}" = codex ] && ! rollout_free "${P_ROLL[$i]}"; then
      case "$HOLD_WHY" in pid*) echo "FAILED $seat: $HOLD_WHY, so it was not started: that would be two writers";; *) echo "FAILED $seat: $HOLD_WHY, so it was not started: it could be a second writer";; esac
      failed=$((failed+1)); continue
    fi
    if ! still_free "$i"; then echo "FAILED $seat: $WHY; it was not started"; failed=$((failed+1)); continue; fi
    if [ -n "${P_CARRY[$i]}" ] && ! carry_folder "$i"; then echo "FAILED $seat: $WHY; it was not started"; failed=$((failed+1)); continue; fi
    if [ "${P_HARNESS[$i]}" = claude ] && [ -n "${P_OLD[$i]}" ]; then
      if ! move_project "${P_OLD[$i]}" "${P_CWD[$i]}" "${P_SID[$i]}"; then echo "FAILED $seat: $WHY; it was not started"; failed=$((failed+1)); continue; fi
      claude_size=$(stat -f %z "$PROJECTS/$(project_key "${P_CWD[$i]}")/${P_SID[$i]}.jsonl")
    fi
    if [ "${P_HARNESS[$i]}" = claude ]; then # the last word before a Claude start: no claude or codex process may work in its folder
      if ! PSOUT=$("$PS_BIN" -axo pid=,command=); then echo "FAILED $seat: the process list cannot be read just before the start; it was not started"; failed=$((failed+1)); continue; fi
      running_in any "${P_CWD[$i]}"; rc=$?
      if [ $rc -eq 0 ]; then echo "FAILED $seat: a claude or codex process works in ${P_CWD[$i]} just before the start; it was not started"; failed=$((failed+1)); continue; fi
      if [ $rc -ne 1 ]; then echo "FAILED $seat: whether a claude or codex process works in ${P_CWD[$i]} cannot be read just before the start ($RUN_ERR); it was not started"; failed=$((failed+1)); continue; fi
    fi
    since=$(date +%s)
    if ! launch "$i"; then echo "FAILED $seat: $LAUNCH_WHY"; unseat "$i"; failed=$((failed+1)); continue; fi
    echo "RESUMED $seat: ${P_HARNESS[$i]} ${P_SID[$i]} (${P_MODE[$i]}; ${P_WHY[$i]}) in ${P_SESS[$i]} at $(TZ=UTC date -r "$since" +%Y-%m-%dT%H:%M:%SZ)"; resumed=$((resumed+1))
    if [ "${P_HARNESS[$i]}" = codex ] && [ $proved_codex -eq 0 ]; then
      prove_codex "$seat" "${P_SID[$i]}" "${P_MARK[$i]}" "$STATE/prompts/$seat.txt" "${P_SESS[$i]}" || { stopped=0; unseat "$i"; recovery "$i"; break; }
      proved_codex=1
    fi
    if [ -n "${P_OLD[$i]}" ] && [ "${P_HARNESS[$i]}" = codex ]; then
      prove_moved "$seat" "${P_SID[$i]}" "${P_ROLL[$i]}" "${P_CWD[$i]}" "${P_SESS[$i]}" "$since" || { stopped=0; unseat "$i"; recovery "$i"; break; }
    fi
    if [ "${P_HARNESS[$i]}" = claude ] && [ $proved_claude -eq 0 ]; then
      prove_claude "$seat" "${P_MARK[$i]}" "${P_SESS[$i]}" || { stopped=0; unseat "$i"; recovery "$i"; break; }
      proved_claude=1
    fi
    if [ -n "${P_OLD[$i]}" ] && [ "${P_HARNESS[$i]}" = claude ]; then
      prove_claude_moved "$seat" "${P_SID[$i]}" "${P_CWD[$i]}" "${P_OLD[$i]}" "${P_SESS[$i]}" "$claude_size" "$STATE/prompts/$seat.txt" || { stopped=0; unseat "$i"; recovery "$i"; break; }
    fi
  done
fi

if [ -n "$CARRY_BAD" ]; then echo "FAILED:$CARRY_BAD: the seat runs in its carried clone, but a linked worktree of it does not reach it. Bring this to zeo-rescue."; failed=$((failed+1)); fi
echo "rescue: live $live, ok $ok, running $running, to resume $resume, to reseat $reseat, resumed $resumed, unresolved $unresolved, failed $failed"
[ $stopped -eq 1 ] || exit 1
[ $failed -eq 0 ] || exit 1
[ $unresolved -eq 0 ] || exit 3
exit 0
