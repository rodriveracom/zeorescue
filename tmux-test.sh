#!/bin/bash
# Real tmux, real ps, the real ~/.zshrc seat loader, on a private socket, with fake harnesses. No seat is touched: the fake programs
# only write down what they were given. rescue-test.sh proves the decisions with stubs; this proves tmux and the loader really do
# what those decisions assume. It needs /opt/homebrew/bin/tmux and the host's seat loader, so it runs here and not in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d /tmp/zr.XXXXXX); SOCK=zrt$$
TM=/opt/homebrew/bin/tmux
trap '"$TM" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }
mkdir -p "$T/w/cl" "$T/w/cx" "$T/w/cxi" "$T/projects" "$T/snap" "$T/sess" "$T/state" "$T/bin"
mkdir -p "$T/h"
for h in claude codex; do
  # a copy of a Homebrew binary, blocking on the terminal: macOS hides the environment of Apple-signed programs such as sleep from ps -E
  cp /opt/homebrew/bin/jq "$T/h/$h"
  cat > "$T/bin/$h" <<S
#!/bin/sh
env | sort > "$T/env.\$ZMAIL_INSTANCE"
printf '%s\n' "\$@" > "$T/args.\$ZMAIL_INSTANCE"
sid=44444444-4444-4444-8444-444444444444; case "\$*" in *45454545-*) sid=45454545-4545-4545-8545-454545454545;; esac
[ "$h" = codex ] && /bin/zsh -ic 'env' </dev/null 2>/dev/null | sed 's/^/export /' > "$T/snap/\$sid.\$\$.sh"
[ -f "$T/badid" ] && [ "$h" = codex ] && sed -i "" -e "s/ZMAIL_INSTANCE=.*/ZMAIL_INSTANCE=other/" "$T/snap/\$sid.\$\$.sh"
# the interactive zsh above takes the terminal, so the fake codex blocks on a pipe instead; like Codex it records its folder and holds its rollout
if [ "$h" = codex ]; then
  roll="$T/sess/full.jsonl"; [ "\$sid" = 44444444-4444-4444-8444-444444444444 ] || roll="$T/sess/i.jsonl"
  prev=; for a in "\$@"; do [ "\$prev" != -C ] || printf '{"cwd":"%s"}\n' "\$a" >> "\$roll"; prev=\$a; done
  mkfifo "$T/f.\$\$"; sleep 300 > "$T/f.\$\$" & exec 9>> "\$roll"; exec "$T/h/$h" --arg a "\$*" . < "$T/f.\$\$"
fi
exec "$T/h/$h" --arg a "\$*" .
S
  chmod +x "$T/bin/$h"
done
cat > "$T/bin/sqlite3" <<S
#!/bin/sh
case "\$*" in
  *"select count(*)"*) echo 0; exit 0;;
  *"select cwd from"*) echo "$T/w/moved"; exit 0;;
  *"$T/w/cxi'"*) printf '%s %s\n' 45454545-4545-4545-8545-454545454545 "$T/sess/i.jsonl"; exit 0;;
esac
printf '%s %s\n' 44444444-4444-4444-8444-444444444444 "$T/sess/full.jsonl"
S
chmod +x "$T/bin/sqlite3"
echo '{"type":"turn_context","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}' > "$T/sess/full.jsonl"
cp "$T/sess/full.jsonl" "$T/sess/i.jsonl"
printf 'export ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=txi\n' > "$T/snap/45454545-4545-4545-8545-454545454545.0.sh"
enc() { printf %s "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }
d=$T/projects/$(enc "$T/w/cl"); mkdir -p "$d"; echo '{"permissionMode":"auto"}' > "$d/22222222-2222-4222-8222-222222222222.jsonl"
row() { printf '{"seat_id":"%s","mailbox":"%s","desired_agent":"%s","desired_host":"h","desired_tmux":{"session":"%s"},"desired_folder":"%s"}' "$1" "$1" "$2" "$3" "$4"; }
echo "{\"seats\":[$(row tc claude tc-s "$T/w/cl"),$(row tx codex tx-s "$T/w/cx"),$(row txi codex txi-s "$T/w/cxi")]}" > "$T/chart.json"
# the git markers the Architect would name for seats whose snapshots record none: nothing defaults
mkdir -p "$T/state"; printf 'tc master\ntx master\n' > "$T/state/seat-markers"
export ZEO_RESCUE_PINS=$T/none ZEO_RESCUE_STATE=$T/state ZEO_RESCUE_LIMIT_WAIT=0 ZEO_RESCUE_CLAUDE_AUTH=/usr/bin/false ZEO_RESCUE_PROJECTS=$T/projects ZEO_RESCUE_CODEX_DB=$T/db ZEO_RESCUE_SNAPSHOTS=$T/snap \
  ZEO_RESCUE_SQLITE=$T/bin/sqlite3 ZEO_RESCUE_CLAUDE=$T/bin/claude ZEO_RESCUE_CODEX=$T/bin/codex ZEO_RESCUE_KILL=/usr/bin/true ZEO_RESCUE_PROOF_TRIES=20 ZEO_RESCUE_PROOF_PAUSE=0.5
: > "$T/db" # the stub answers the SQL; the database file is only copied (db_read)
R() { "$HERE/rescue.sh" --host h --socket "$SOCK" --stagger 0 --chart "$T/chart.json" "$@"; }

echo "-- a dead seat comes up through real tmux and the real loader"
out=$(R --apply 2>&1); rc=$?
echo "$out" | sed 's/^/     /' | cut -c1-140
[ $rc -eq 0 ] && ok "rescue exits 0" || bad "exit $rc"
echo "$out" | grep -q 'FIRST SEAT OK tc: own identity, marker master, git on' && ok "the claude path proves itself from the live process" || bad "claude proof"
echo "$out" | grep -q 'FIRST SEAT OK tx: own identity, marker master, git on' && ok "the codex path proves itself from a snapshot" || bad "codex proof"
grep -q '^ZEO_TMUX_SEAT=master$' "$T/env.tc" && ok "the seat loader saw the pane marker on its first run" || bad "loader: $(grep ZEO_TMUX "$T/env.tc")"
grep -q '^GIT_ALLOW_PROTOCOL=file$' "$T/env.tc" && bad "git is off" || ok "git is on"
grep -q '^CLAUDECODE=' "$T/env.tc" && bad "the rescuer's environment leaked into the seat" || ok "the rescuer's environment did not leak"
grep -qx -- '--no-daemon' "$T/args.tx" && ok "codex got --no-daemon" || bad "no --no-daemon"
[ "$("$TM" -L "$SOCK" list-panes -s -t '=tc-s' -F '#{@zeo_seat} #{@zeo_rescue}')" = "master 1" ] && ok "the pane carries both options" || bad "pane options"
tail -1 "$T/args.tc" | grep -q 'You were restarted' && ok "the prompt arrives as one argument" || bad "prompt"
grep -q '^ZEO_TMUX_SEAT=master$' "$T/env.tx" && ok "a codex process has its marker, not only a snapshot" || bad "codex process marker"
grep -q '^GIT_AUTHOR_EMAIL=.*noreply' "$T/env.tx" && ok "and its author" || bad "codex process author"
grep -q '^GIT_ALLOW_PROTOCOL=file$' "$T/env.tx" && bad "codex process has git off" || ok "and git on"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -f "$T/env.txi" ] && break; perl -e 'select(undef,undef,undef,0.5)'; done; perl -e 'select(undef,undef,undef,1.5)' # only the first seat is proved, so the run returns before the last one is up
grep -q '^ZEO_TMUX_SEAT=inactive$' "$T/env.txi" && grep -q '^GIT_ALLOW_PROTOCOL=file$' "$T/env.txi" && grep -q '^GIT_SSH_COMMAND=/usr/bin/false$' "$T/env.txi" && ok "an inactive codex process has git off" || bad "inactive process"
out=$(R --check --seat tc --seat tx 2>&1); rc=$?
[ $rc -eq 0 ] && ok "--check passes them" || bad "check: $out"
out=$(R --check --seat txi 2>&1)
echo "$out" | grep -q 'git on\|no seat settings\|process says' && bad "inactive: $out" || ok "--check finds git off in a shell outside an inactive seat's folder"

echo "-- a live seat started the wrong way is reseated"
"$TM" -L "$SOCK" kill-session -t '=tc-s'
"$TM" -L "$SOCK" new-session -d -s tc-s -c "$T/w/cl" -- "$T/bin/claude" --resume 22222222-2222-4222-8222-222222222222
"$TM" -L "$SOCK" new-window -d -t '=tc-s' -- sleep 300
perl -e 'select(undef,undef,undef,0.5)'
rm -f "$T/env.tc"
out=$(R --reseat --apply --seat tc 2>&1); rc=$?
echo "$out" | sed 's/^/     /' | cut -c1-140
[ $rc -eq 0 ] && ok "reseat exits 0" || bad "reseat exit $rc"
[ "$(pgrep -f -- "$T/h/claude .*22222222-2222-4222-8222-222222222222" | wc -l | tr -d ' ')" = 1 ] && ok "only one process holds the session" || bad "two holders"
grep -q '^ZEO_TMUX_SEAT=master$' "$T/env.tc" && ok "the reseated seat has its marker" || bad "reseat marker"
[ "$("$TM" -L "$SOCK" list-panes -s -t '=tc-s' | wc -l | tr -d ' ')" = 2 ] && ok "the side window survived" || bad "side window"
grep -q '^OK tc: started by rescue' <<< "$(R --reseat --seat tc 2>&1)" && ok "a second reseat leaves it alone" || bad "second reseat"

echo "-- a seat that fails its proof goes back to sleep, and the next run takes it"
pane=$("$TM" -L "$SOCK" list-panes -s -t '=tx-s' -F '#{pane_id}' | head -1)
"$TM" -L "$SOCK" set-option -pu -t "$pane" @zeo_rescue
touch "$T/badid"
out=$(R --reseat --apply --seat tx 2>&1); rc=$?
echo "$out" | sed 's/^/     /' | cut -c1-140
[ $rc -eq 1 ] && echo "$out" | grep -q 'STOPPED: tx did not get its own identity' && ok "a wrong identity stops the run" || bad "proof: $rc"
echo "$out" | grep -q '^RECOVERY: 1 seats' && ok "and says what is down" || bad "recovery"
perl -e 'select(undef,undef,undef,0.3)'
[ "$("$TM" -L "$SOCK" list-panes -s -t '=tx-s' -F '#{pane_current_command}|#{@zeo_rescue}' | head -1)" = "sleep|" ] && ok "the wrong seat is back on a sleep, with no rescue mark" || bad "pane: $("$TM" -L "$SOCK" list-panes -s -t '=tx-s' -F '#{pane_current_command}|#{@zeo_rescue}')"
grep -q '^RESEAT tx:' <<< "$(R --reseat --seat tx 2>&1)" && ok "the next plan takes it, not skips it" || bad "replan"
grep -q '^WRONG tx' <<< "$(R --check --seat tx 2>&1)" && ok "--check names it wrong meanwhile" || bad "check while down"

echo "-- real lsof sees what holds a rollout"
rm -f "$T/badid"
sleep 60 < "$T/sess/full.jsonl" & holder=$!
perl -e 'select(undef,undef,undef,0.3)'
out=$(ZEO_RESCUE_STOP_TRIES=2 R --reseat --apply --seat tx 2>&1); rc=$?
echo "$out" | sed 's/^/     /' | cut -c1-140
echo "$out" | grep -q "^FAILED tx: pid $holder still holds its rollout" && ok "a real holder refuses the start" || bad "holder $holder"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
out=$(R --reseat --apply --seat tx 2>&1); rc=$?
echo "$out" | sed 's/^/     /' | cut -c1-140
[ $rc -eq 0 ] && echo "$out" | grep -q 'FIRST SEAT OK tx' && ok "with nothing holding it the same line brings the seat back" || bad "recovered: $rc"
out=$(R --check --seat tx 2>&1); [ $? -eq 0 ] && ok "and --check passes it" || bad "check after: $out"

echo "-- a codex seat started the old way, with the loader only in its snapshot"
pane=$("$TM" -L "$SOCK" list-panes -s -t '=tx-s' -F '#{pane_id}' | head -1)
"$TM" -L "$SOCK" respawn-pane -k -t "$pane" -c "$T/w/cx" -- /usr/bin/env -i HOME="$HOME" ZMAIL_INSTANCE=tx /bin/zsh -lc 'exec "$@"' old "$T/bin/codex" resume --no-daemon 44444444-4444-4444-8444-444444444444 p
perl -e 'select(undef,undef,undef,1.5)'
grep -q '^WRONG tx (codex): process has no seat settings' <<< "$(R --check --seat tx 2>&1)" && ok "--check names it, though its snapshot looks right" || bad "old way: $(R --check --seat tx 2>&1)"

echo "-- --relaunch moves that seat to a new folder, on real tmux"
mkdir -p "$T/w/moved" "$T/sessions"; : > "$T/sessions/rollout-44444444-4444-4444-8444-444444444444.jsonl"
echo "tx $T/w/moved" > "$T/moves"; echo "tx 44444444-4444-4444-8444-444444444444" > "$T/pins"
export ZEO_RESCUE_MOVES=$T/moves ZEO_RESCUE_PINS=$T/pins ZEO_RESCUE_SESSIONS=$T/sessions ZEO_RESCUE_CODEX_CONFIG=$T/none.toml
"$TM" -L "$SOCK" new-window -d -t '=tx-s' -- sleep 300
out=$(R --reseat --relaunch --apply --seat tx 2>&1); rc=$?
echo "$out" | sed 's/^/     /' | cut -c1-140
[ $rc -eq 0 ] && echo "$out" | grep -q "^MOVED OK tx: thread 44444444-4444-4444-8444-444444444444, one rollout, one writer, in $T/w/moved" && ok "the first seat moves and proves it, with a real lsof on its rollout" || bad "move: $rc $out"
[ "$(pgrep -f -- "$T/h/codex .*44444444-4444-4444-8444-444444444444" | wc -l | tr -d ' ')" = 1 ] && ok "one process holds the thread" || bad "two holders"
p=$("$TM" -L "$SOCK" list-panes -t "=tx-s:" -F "#{pane_pid}" | head -1); [ "$(/usr/sbin/lsof -a -d cwd -Fn -p "$p" 2>/dev/null | sed -n "s/^n//p" | head -1)" = "$(cd "$T/w/moved" && pwd -P)" ] && ok "the process really runs in the new folder" || bad "process folder: $(/usr/sbin/lsof -a -d cwd -Fn -p "$p" 2>/dev/null | tail -1)"
[ "$("$TM" -L "$SOCK" list-panes -s -t '=tx-s' | wc -l | tr -d ' ')" = 2 ] && ok "its side window survived" || bad "side window"
grep -q 'moved from' "$T/state/prompts/tx.txt" && ok "the prompt tells it" || bad "prompt"
out=$(R --check --seat tx 2>&1); [ $? -eq 0 ] && ok "--check passes it in the new folder" || bad "moved check: $out"
grep -q '^OK tx: started by rescue, right already' <<< "$(R --reseat --relaunch --seat tx 2>&1)" && ok "a second run leaves it alone" || bad "second: $(R --reseat --relaunch --seat tx 2>&1)"
"$TM" -L "$SOCK" kill-session -t '=tx-s'; perl -e 'select(undef,undef,undef,0.5)'
out=$(R --seat tx 2>&1); echo "$out" | grep -q '^RESUME tx: codex 44444444-4444-4444-8444-444444444444' && echo "$out" | grep -q "^MOVE tx: from $T/w/cx to $T/w/moved" && ok "after a crash the pin still finds its thread, and it stays in the new folder" || bad "after crash: $out"
export ZEO_RESCUE_MOVES=$T/none ZEO_RESCUE_PINS=$T/none
echo; [ $fails -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
