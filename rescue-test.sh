#!/bin/bash
# Hermetic: every external tool is a stub in a temp directory, and nothing touches a real tmux server, transcript or database.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fails=$((fails+1)); }
GOOD='ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct GIT_ALLOW_PROTOCOL=ssh:https:file GH_CONFIG_DIR=/x/gh-master'
mkdir -p "$T/bin" "$T/projects" "$T/state" "$T/w/cl" "$T/w/cl2" "$T/w/cx" "$T/w/cxw" "$T/w/cxi" "$T/w/cxn" "$T/w/none" "$T/sess" "$T/snap"
# The tmux stub keeps a list of live sessions, and a pane per session in $T/panes (session|id|pid|opt|cmd) when a test wants one.
cat > "$T/bin/tmux" <<S
#!/bin/bash
echo "\$*" >> "$T/tmux.log"
case "\$3" in
  has-session) c="$T/has.\${5#=}"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$c"; [ "\$n" -ne 2 ] || [ ! -f "$T/onhas2" ] || bash "$T/onhas2"; grep -qxF "\${5#=}" "$T/live" 2>/dev/null ;;
  new-session) if [ -f "$T/newsess-taken" ]; then echo "\$6" >> "$T/live"; exit 1; fi; printf '%s\n' "\$*" >> "$T/launched"; echo "\$6" >> "$T/live" ;;
  list-panes)  s=\${6#=}; if grep -q "^\$s|" "$T/panes" 2>/dev/null; then grep "^\$s|" "$T/panes" | cut -d'|' -f2-; else echo "%\$s|9|1|sleep"; fi ;;
  set-option)  [ ! -f "$T/optfail" ] || exit 1; printf '%s\n' "\$*" >> "$T/opts" ;;
  show-options) cat "$T/seatmark" 2>/dev/null ;;
  capture-pane) [ ! -f "$T/capfail" ] || exit 1; [ ! -f "$T/screen" ] || cat "$T/screen" ;;
  respawn-pane) printf '%s\n' "\$*" >> "$T/launched"; [ ! -f "$T/onrespawn" ] || bash "$T/onrespawn" "\$*"
    case "\$*" in *" -- sleep 3600") [ ! -f "$T/onstop" ] || bash "$T/onstop";; esac
    case "\$*" in *" --resume "*) sid=\$(printf "%s\n" "\$*" | sed -E "s/.* --resume ([^ ]+).*/\\1/"); if [ -f "$T/claudeadd" ]; then for f in "$T"/projects/*/\$sid.jsonl; do cat "$T/claudeadd" >> "\$f"; done; fi; printf "9 /x/claude --resume %s\n" "\$sid" >> "$T/ps.out"; [ ! -f "$T/secondclaude" ] || printf "77 /x/claude --resume %s\n" "\$sid" >> "$T/ps.out"; if [ -f "$T/forksession" ]; then for f in "$T"/projects/*/\$sid.jsonl; do : > "\${f%/*}/99999999-9999-4999-8999-999999999999.jsonl"; done; fi;; esac;
    case "\$*" in *" resume "*--no-daemon*) id=\${@: -1}; if [ -f "$T/snapwrite" ]; then cp "$T/snapwrite" "$T/snap/\$id.new.sh"; fi; [ ! -f "$T/heldafter" ] || cp "$T/heldafter" "$T/lsof.held"; [ ! -f "$T/latehold" ] || touch "$T/heldlate"; [ ! -f "$T/rolladd" ] || cat "$T/rolladd" >> "$T/sess/full.jsonl" ;; esac ;;
esac
exit \$?
S
cat > "$T/bin/ps" <<S
#!/bin/bash
case "\$1" in
  -Ewwp) if [ -s "$T/psE.out" ]; then cat "$T/psE.out"; else echo "$GOOD"; fi ;;
  -axo) [ ! -f "$T/ps.fail" ] || exit 2; cat "$T/ps.out" 2>/dev/null ;;
  *) cat "$T/ps.out" 2>/dev/null ;;
esac
exit 0
S
cat > "$T/bin/lsof" <<S
#!/bin/bash
# A failure, when a test asks for one: exit with the status on the first line of the file, its other lines on stderr, and on stdout only what FILE.out holds.
case " \$* " in *" -d cwd -Fn -p "*) f="$T/lsof.fail-run";; *" -t "*) f="$T/lsof.fail-t";; *" -Fpn "*) f="$T/lsof.fail-cwd";; *) f="";; esac
if [ -n "\$f" ] && [ -f "\$f" ]; then [ ! -f "\$f.out" ] || cat "\$f.out"; sed -n "2,\\\$p" "\$f" >&2; exit "\$(head -1 "\$f")"; fi
case "\$1" in -p) cat "$T/lsof.txt" 2>/dev/null ;; -t) echo "\$*" >> "$T/lsof.args"; if [ -f "$T/heldlate" ]; then rm -f "$T/heldlate"; else cat "$T/lsof.held" 2>/dev/null; fi ;; -Fn) cat "$T/lsof.daemon" 2>/dev/null ;; *) cat "$T/lsof.out" 2>/dev/null ;; esac
S
cat > "$T/bin/kill" <<S
#!/bin/bash
echo "\$*" >> "$T/kills"
S
cat > "$T/bin/sqlite3" <<S
#!/bin/bash
echo "\$1" >> "$T/sqlargs"
case "\$2" in
  *"select count(*)"*) cat "$T/newthreads" ;;
  *"select cwd from"*) cat "$T/threadcwd" ;;
  *"$T/w/cx'"*|*"44444444-4444-4444-8444-444444444444"*)  printf '%s %s\n' 44444444-4444-4444-8444-444444444444 "$T/sess/full.jsonl" ;;
  *"$T/w/cxw'"*) printf '%s %s\n' 55555555-5555-4555-8555-555555555555 "$T/sess/write.jsonl" ;;
  *"$T/w/cxi'"*) printf '%s %s\n' 66666666-6666-4666-8666-666666666666 "$T/sess/full.jsonl" ;;
  *"$T/w/cxn'"*) printf '%s %s\n' 77777777-7777-4777-8777-777777777777 "$T/sess/full.jsonl" ;;
esac
S
# The probe shell stands in for zsh reading the host's .zshenv: it gives a master seat its author, and can reset gh as the real file does.
cat > "$T/bin/zsh-probe" <<S
#!/bin/bash
env | sort > "$T/probe.env"
[ ! -f "$T/zshenv-resets-gh" ] || GH_CONFIG_DIR=/x/gh-acct
[ "\$1" != -c ] || [ ! -f "$T/plain-c-git-on" ] || GIT_ALLOW_PROTOCOL=ssh
[ "\$ZEO_TMUX_SEAT:\${ZEO_TMUX_ACCOUNT:-}" != master:acct ] || GIT_AUTHOR_EMAIL=a@noreply
echo "gh=\${GH_CONFIG_DIR##*/} author=\${GIT_AUTHOR_EMAIL:-none}"
[ "\${GIT_ALLOW_PROTOCOL:-}" != file ] || echo "fatal: transport 'ssh' not allowed"
S
chmod +x "$T/bin/"*
echo master > "$T/seatmark"
: > "$T/ps.out"; : > "$T/lsof.out"; : > "$T/psE.out"
echo '{"type":"turn_context","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"}}' > "$T/sess/full.jsonl"
echo '{"type":"turn_context","approval_policy":"never","sandbox_policy":{"type":"workspace-write"}}' > "$T/sess/write.jsonl"
printf 'export ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=cx\nexport GIT_ALLOW_PROTOCOL=ssh:https:file\n' > "$T/snap/44444444-4444-4444-8444-444444444444.1.sh"
printf 'export ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=cxi\nexport GIT_ALLOW_PROTOCOL=file\n' > "$T/snap/66666666-6666-4666-8666-666666666666.1.sh"
touch -t 202601010000 "$T/snap/44444444-4444-4444-8444-444444444444.1.sh"
enc() { printf %s "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }
d=$T/projects/$(enc "$T/w/cl"); mkdir -p "$d"
echo '{"permissionMode":"plan"}'  > "$d/11111111-1111-4111-8111-111111111111.jsonl"
echo '{"permissionMode":"auto"}'  > "$d/22222222-2222-4222-8222-222222222222.jsonl"
touch -t 202601010000 "$d/11111111-1111-4111-8111-111111111111.jsonl"
d2=$T/projects/$(enc "$T/w/cl2"); mkdir -p "$d2"
echo '{"nothing":"here"}' > "$d2/33333333-3333-4333-8333-333333333333.jsonl"
row() { printf '{"seat_id":"%s","mailbox":"%s","desired_agent":"%s","desired_host":"%s","desired_tmux":{"session":"%s"},"desired_folder":"%s"}' "$@"; }
cat > "$T/chart.json" <<J
{"seats":[
 $(row cl cl claude h cl-maintainer "$T/w/cl"),
 $(row nomode nomode claude h nomode-s "$T/w/cl2"),
 $(row cx cx codex h cx-maintainer "$T/w/cx"),
 $(row cxw cxw codex h cxw-s "$T/w/cxw"),
 $(row cxi cxi codex h cxi-s "$T/w/cxi"),
 $(row cxn cxn codex h cxn-s "$T/w/cxn"),
 $(row alias other codex h alias-s "$T/w/cx"),
 $(row nothread nothread codex h nothread-s "$T/w/none"),
 $(row elsewhere elsewhere claude other-host e-s "$T/w/cl"),
 $(row zeo-rescue zeo-rescue claude h zeo-rescue "$T/w/cl"),
 {"seat_id":"disposable","mailbox":"x","desired_agent":null,"desired_host":null,"desired_tmux":null,"desired_folder":""}
]}
J
export ZEO_RESCUE_ZSH="$T/bin/zsh-probe" ZEO_RESCUE_CLAUDE_JSON="$T/claude.json"
export ZEO_RESCUE_PINS="$T/no-pins" ZEO_RESCUE_STATE="$T/state" ZEO_RESCUE_PROJECTS="$T/projects" ZEO_RESCUE_CODEX_DB="$T/db" ZEO_RESCUE_TMUX="$T/bin/tmux" ZEO_RESCUE_SNAPSHOTS="$T/snap" \
  ZEO_RESCUE_SQLITE="$T/bin/sqlite3" ZEO_RESCUE_PS="$T/bin/ps" ZEO_RESCUE_LSOF="$T/bin/lsof" ZEO_RESCUE_KILL="$T/bin/kill" ZEO_RESCUE_CLAUDE=/x/claude ZEO_RESCUE_CODEX=/x/codex \
  ZEO_RESCUE_PROOF_TRIES=2 ZEO_RESCUE_PROOF_PAUSE=0 ZEO_RESCUE_STOP_TRIES=2 ZEO_RESCUE_DAEMON_WAIT=0 ZEO_RESCUE_LIMIT_WAIT=0
: > "$T/db" # the stub answers the SQL; the database file is only copied (db_read)
# The per-seat git markers the Architect would name for seats whose snapshots record none (every Claude seat): nothing defaults.
printf 'cl master\ncxw inactive\ncxn master\nka master\n' > "$T/state/seat-markers"
R() { "$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart.json" "$@"; }

echo "-- the plan"
out=$(R 2>&1); rc=$?
[ ! -e "$T/launched" ] && ok "a plan starts nothing" || bad "a plan started something"
[ $rc -eq 3 ] && ok "UNRESOLVED seats exit 3" || bad "exit $rc, want 3"
echo "$out" | grep -q '^RESUME cl: claude 22222222-2222-4222-8222-222222222222 (--permission-mode auto; marker master, named in seat-markers) in cl-maintainer' && ok "newest transcript, its recorded mode, the chart's session label, the marker its seat-markers line names" || bad "claude plan: $out"
echo "$out" | grep -q '^RESUME cx: codex 44444444-4444-4444-8444-444444444444 (-a never -s danger-full-access; marker master, recorded)' && ok "a codex seat gets its own recorded mode and marker" || bad "codex plan: $out"
echo "$out" | grep -q '^RESUME cxw: codex 55555555-5555-4555-8555-555555555555 (-a never -s workspace-write; no marker, named inactive in seat-markers)' && ok "a seat named inactive in seat-markers gets no marker" || bad "workspace-write: $out"
echo "$out" | grep -q '^RESUME cxi: .*no marker, recorded inactive' && ok "a seat recorded inactive stays inactive" || bad "inactive: $out"
echo "$out" | grep -q '^RESUME cxn: .*marker master, named in seat-markers' && ok "a seat with no snapshot record gets the marker its seat-markers line names" || bad "default: $out"
echo "$out" | grep -q '^UNRESOLVED nomode: transcript records no permission mode' && ok "no recorded mode is UNRESOLVED, never a default" || bad "no-mode seat"
echo "$out" | grep -q '^UNRESOLVED alias: mailbox is other' && ok "a mailbox that is not the seat id is not guessed" || bad "alias"
echo "$out" | grep -q '^UNRESOLVED nothread: no Codex thread' && ok "no thread is UNRESOLVED" || bad "no thread"
echo "$out" | grep -q 'elsewhere' && bad "another host's seat was planned" || ok "another host's seat is left out"
echo "$out" | grep -q 'disposable' && bad "a seat with no agent was planned" || ok "a seat with no agent is left out"
echo "$out" | grep -q 'zeo-rescue' && bad "the rescue seat planned itself" || ok "the rescue seat never starts itself"
[ -f "$T/state/ORG-CHART.last-good.json" ] && ok "the last good chart is kept" || bad "no last good chart"

echo "-- the git marker is the seat's own record or its explicit line, never a default"
MK() { ZEO_RESCUE_MARKERS="$1" R "${@:2}" 2>&1; }
out=$(MK "$T/no-markers" --seat cl); rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q '^UNRESOLVED cl: no recorded git marker' && ! echo "$out" | grep -q '^RESUME cl' && ok "a Claude seat with no seat-markers line is UNRESOLVED, not given master" || bad "no marker line: $rc $out"
n0=$(cat "$T/launched" 2>/dev/null | wc -l | tr -d ' '); out=$(MK "$T/no-markers" --apply --seat cl); rc=$?
[ $rc -eq 3 ] && [ "$(cat "$T/launched" 2>/dev/null | wc -l | tr -d ' ')" = "$n0" ] && ! grep -q 'set-option.*@zeo_seat' "$T/opts" 2>/dev/null && ok "and --apply starts nothing and sets no marker for it" || bad "no marker apply: $rc $out"
out=$(MK "$T/no-markers" --seat cxw); rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q '^UNRESOLVED cxw: no recorded git marker' && ok "a workspace-write sandbox is not taken as a marker either" || bad "sandbox inferred: $rc $out"
printf 'cl admin\n' > "$T/bad-markers"; out=$(MK "$T/bad-markers" --seat cl)
echo "$out" | grep -q "^UNRESOLVED cl: its line in .* names 'admin'" && ok "an unknown marker in seat-markers is UNRESOLVED" || bad "bad marker: $out"
printf 'cl master extra\n' > "$T/bad-markers"; out=$(MK "$T/bad-markers" --seat cl)
echo "$out" | grep -q "^UNRESOLVED cl: its line in .* names 'master ?'" && ok "so is a line with more than a seat and a marker" || bad "long line: $out"
printf 'cl master\ncl inactive\n' > "$T/bad-markers"; out=$(MK "$T/bad-markers" --seat cl)
echo "$out" | grep -q '^UNRESOLVED cl: more than one line for it' && ok "two lines for one seat are UNRESOLVED" || bad "two lines: $out"
printf 'cx inactive\n' > "$T/bad-markers"; out=$(MK "$T/bad-markers" --seat cx)
echo "$out" | grep -q '^RESUME cx: .*marker master, recorded' && ok "the seat's own snapshot record comes before its seat-markers line" || bad "snapshot first: $out"

echo "-- naming the session"
grep -q '^RESUME cl: claude 11111111-1111-4111-8111-111111111111 (--permission-mode plan' <<< "$(R --seat cl --session 11111111-1111-4111-8111-111111111111 2>&1)" && ok "--session beats the newest transcript, with that session's own mode" || bad "--session"
R --seat cl --seat cx --session 11111111-1111-4111-8111-111111111111 >/dev/null 2>&1; [ $? -eq 2 ] && ok "--session needs exactly one seat" || bad "--session with two seats"
grep -q '^UNRESOLVED cl: no transcript' <<< "$(R --seat cl --session 99999999-9999-4999-8999-999999999999 2>&1)" && ok "a --session with no transcript is UNRESOLVED" || bad "--session missing"

printf "cl 11111111-1111-4111-8111-111111111111\n" > "$T/pins"
grep -q '^RESUME cl: claude 11111111-1111-4111-8111-111111111111' <<< "$(ZEO_RESCUE_PINS=$T/pins R --seat cl 2>&1)" && ok "a pin beats the newest transcript" || bad "pin"
printf "cl not-an-id\n" > "$T/pins"
grep -q '^UNRESOLVED cl: bad pin' <<< "$(ZEO_RESCUE_PINS=$T/pins R --seat cl 2>&1)" && ok "a bad pin is UNRESOLVED" || bad "bad pin"

echo "-- a recorded marker older than a fault"
printf 'export ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=other\n' > "$T/snap/44444444-4444-4444-8444-444444444444.2.sh"
grep -q '^RESUME cx: .*no marker, recorded inactive' <<< "$(R --seat cx 2>&1)" && ok "without --before the newest snapshot speaks" || bad "newest"
grep -q '^RESUME cx: .*marker master, recorded' <<< "$(R --seat cx --before 202601020000 2>&1)" && ok "--before ignores snapshots written during the fault" || bad "--before"
rm -f "$T/snap/44444444-4444-4444-8444-444444444444.2.sh"

echo "-- not running twice"
echo "4242 claude" > "$T/ps.out"; printf 'p4242\nfcwd\nn%s\n' "$T/w/cl" > "$T/lsof.out"
grep -q '^RUNNING cl:' <<< "$(R 2>&1)" && ok "a process in the seat's directory is left alone" || bad "RUNNING"
echo "4242 /u/.local/share/claude/versions/2.1.318 --resume x" > "$T/ps.out"
grep -q '^RUNNING cl:' <<< "$(R 2>&1)" && ok "the versioned binary path counts as claude" || bad "versioned path"
: > "$T/ps.out"; : > "$T/lsof.out"

echo "-- the launch"
cp "$T/snap/44444444-4444-4444-8444-444444444444.1.sh" "$T/snapwrite"
printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=cl GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x' > "$T/psE.out"
printf 'the note' > "$T/note"
out=$(R --apply --seat cl --seat cx --note-file "$T/note" 2>&1)
[ "$(grep -c 'new-session' "$T/launched")" = 2 ] && ok "--seat limits --apply" || bad "launched: $(cat "$T/launched")"
grep -q -- "new-session -d -s cl-maintainer -c $T/w/cl -- sleep" "$T/launched" && ok "a session starts on a sleep, so no shell runs before the marker" || bad "launch line: $(cat "$T/launched")"
first=$(grep -n 'set-option -p -t %cl-maintainer @zeo_seat master' "$T/tmux.log" | head -1 | cut -d: -f1); spawn=$(grep -n 'respawn-pane -k -t %cl-maintainer' "$T/tmux.log" | head -1 | cut -d: -f1)
[ -n "$first" ] && [ -n "$spawn" ] && [ "$first" -lt "$spawn" ] && ok "the marker is set before the seat starts" || bad "marker order: $first $spawn"
grep -q -- "seat-exec.sh cl claude $T/state/prompts/cl.txt /x/claude --resume 22222222-2222-4222-8222-222222222222 --permission-mode auto" "$T/launched" && ok "claude argv" || bad "claude argv: $(cat "$T/launched")"
grep -q -- "seat-exec.sh cx codex $T/state/prompts/cx.txt /x/codex resume -a never -s danger-full-access -C $T/w/cx --no-daemon 44444444-4444-4444-8444-444444444444" "$T/launched" && ok "codex argv has --no-daemon and -C" || bad "codex argv: $(cat "$T/launched")"
grep -q 'the note$' "$T/state/prompts/cx.txt" && ok "the note joins the prompt" || bad "note"
echo "$out" | grep -q 'FIRST SEAT OK cx: own identity, marker master, git on' && ok "the first codex seat is proved" || bad "codex proof: $out"
echo "$out" | grep -q 'FIRST SEAT OK cl: own identity, marker master, git on' && ok "the first claude seat is proved" || bad "claude proof: $out"
grep -q '^LIVE cl ' <<< "$(R --seat cl --seat cx 2>&1)" && ok "a later run leaves a live seat alone" || bad "second run"
rm -f "$T/snap/44444444-4444-4444-8444-444444444444.new.sh"

echo "-- the seat-exec environment"
cat > "$T/bin/zsh-out" <<S
#!/bin/sh
env | sort > "$T/seatenv"
echo "\$@" > "$T/seatargs"
S
chmod +x "$T/bin/zsh-out"
printf 'hello world' > "$T/p"
sed "s#/bin/zsh -lic 'exec \"\$@\"' zeo-rescue#$T/bin/zsh-out -lic#" "$HERE/seat-exec.sh" > "$T/seat-exec.sh"
SECRET_LEAK=1 TMUX=/t TMUX_PANE=%9 sh "$T/seat-exec.sh" sx codex "$T/p" /x/codex resume id
grep -q '^ZMAIL_INSTANCE=sx$' "$T/seatenv" && ok "the seat gets its own identity" || bad "identity"
grep -q '^TMUX_PANE=%9$' "$T/seatenv" && ok "the loader can find its pane" || bad "pane"
grep -q SECRET_LEAK "$T/seatenv" && bad "the environment leaked" || ok "the environment is clean"
grep -q '^-lic /x/codex resume id hello world$' "$T/seatargs" && ok "a codex seat gets an interactive shell, so .zshrc runs, and the prompt" || bad "seat args: $(cat "$T/seatargs")"
sh "$T/seat-exec.sh" sy claude "$T/p" /x/claude; grep -q '^-lic ' "$T/seatargs" && ok "a claude seat gets an interactive shell, so .zshrc runs" || bad "claude flags"

echo "-- the first seat gate"
reset_live() { : > "$T/live"; : > "$T/launched"; : > "$T/opts"; : > "$T/tmux.log"; : > "$T/panes"; rm -f "$T/kills" "$T/snap/"*.new.sh; }
reset_live
printf 'export ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=seat-b\nexport GIT_ALLOW_PROTOCOL=file\n' > "$T/snapwrite"
out=$(R --apply --seat cx --seat cxn 2>&1); rc=$?
[ $rc -eq 1 ] && ok "a wrong first seat exits 1" || bad "exit $rc"
echo "$out" | grep -q 'STOPPED: cx did not get its own identity' && ok "another seat's identity stops the run" || bad "gate: $out"
[ "$(grep -c new-session "$T/launched")" = 1 ] && ok "no other seat was started" || bad "gate started others"
reset_live
printf 'export ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=cx\nexport GIT_ALLOW_PROTOCOL=file\n' > "$T/snapwrite"
grep -q 'STOPPED: cx lacks marker master' <<< "$(R --apply --seat cx 2>&1)" && ok "a missing marker stops the run" || bad "marker gate"
reset_live; rm -f "$T/snapwrite"
grep -q 'STOPPED: no shell snapshot for cx' <<< "$(R --apply --seat cx 2>&1)" && ok "no snapshot stops the run" || bad "no snapshot gate"
# the gate runs above killed the sessions they made; the stub keeps their fake processes, which a real kill would have ended
reset_live; : > "$T/ps.out"; printf 'ZMAIL_INSTANCE=other-seat HOME=/x' > "$T/psE.out"
grep -q 'STOPPED: cl did not get its own identity' <<< "$(R --apply --seat cl 2>&1)" && ok "a claude seat with another identity stops the run" || bad "claude gate"
reset_live; : > "$T/ps.out"; printf 'ZEO_TMUX_SEAT=inactive ZMAIL_INSTANCE=cl GIT_ALLOW_PROTOCOL=file HOME=/x' > "$T/psE.out"
grep -q 'STOPPED: cl lacks marker master' <<< "$(R --apply --seat cl 2>&1)" && ok "a claude seat without its marker stops the run" || bad "claude marker gate"

: > "$T/psE.out"
reset_live; printf 'export ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=cx\nexport GIT_ALLOW_PROTOCOL=ssh:https:file\n' > "$T/snapwrite"; printf 'HOME=/x' > "$T/psE.out"
out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q '^STOPPED: cx: process has no seat settings, so tools outside its folder miss them; no other seat was started' && ok "a right snapshot does not pass a first seat whose process lacks the settings" || bad "process gate: $rc $out"
printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct GIT_ALLOW_PROTOCOL=file' > "$T/psE.out"
grep -q '^STOPPED: cx: a shell outside its folder has git off' <<< "$(reset_live; R --apply --seat cx 2>&1)" && ok "nor one whose shells have git off" || bad "shell gate"
: > "$T/psE.out"; reset_live; rm -f "$T/snapwrite"

echo "-- the proof reads top-level exports only: a real snapshot also stores the loader's functions"
loader='zeo-seat-load () {\n\tif [ -z "$m" ]\n\tthen\n\t\texport GIT_ALLOW_PROTOCOL=file \n\t\texport ZEO_TMUX_SEAT=inactive \n\tfi\n}\n'
snap() { reset_live; printf "$loader$1" > "$T/snapwrite"; R --apply --seat cx 2>&1; }
out=$(snap 'export GIT_ALLOW_PROTOCOL=ssh:https:file\nexport ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=cx\n')
echo "$out" | grep -q 'FIRST SEAT OK cx: own identity, marker master, git on' && ok "git on at top level passes, though the loader function says file" || bad "loader false stop: $out"
out=$(snap 'export GIT_ALLOW_PROTOCOL=file\nexport ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=cx\n')
echo "$out" | grep -q 'STOPPED: cx still has network git off' && ok "git off at top level still stops" || bad "git off passed: $out"
loader='zeo-seat-load () {\n\t\texport ZEO_TMUX_SEAT=master \n\t\texport ZMAIL_INSTANCE=cx \n}\n'
out=$(snap 'export GIT_ALLOW_PROTOCOL=ssh:https:file\nexport ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=cx\n')
echo "$out" | grep -q 'STOPPED: cx lacks marker master' && ok "a marker only inside a function does not pass" || bad "marker: $out"
out=$(snap 'export GIT_ALLOW_PROTOCOL=ssh:https:file\nexport ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=seat-b\n')
echo "$out" | grep -q 'STOPPED: cx did not get its own identity' && ok "an identity only inside a function does not pass" || bad "identity: $out"
out=$(snap "export GIT_ALLOW_PROTOCOL='ssh:https:file'\nexport ZEO_TMUX_SEAT='master'\nexport ZMAIL_INSTANCE='cx'\n")
echo "$out" | grep -q 'FIRST SEAT OK cx' && ok "a quoted top-level value still passes" || bad "quoted: $out"
reset_live; rm -f "$T/snapwrite"

echo "-- reseating a live seat"
reset_live
printf 'export ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=cx\nexport GIT_ALLOW_PROTOCOL=ssh:https:file\n' > "$T/snapwrite"
echo cx-maintainer >> "$T/live"; echo cxn-s >> "$T/live"
# cx-maintainer has a side window with another program; only the pane that holds the thread is touched
{ echo 'cx-maintainer|%7|700||Python'; echo 'cx-maintainer|%8|800||codex'; echo 'cxn-s|%2|200|1|codex'; } > "$T/panes"
{ echo "700 /usr/bin/python3 collector"; echo "800 /x/codex resume -a never -s danger-full-access 44444444-4444-4444-8444-444444444444 prompt"; echo "900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server"; } > "$T/ps.out"
out=$(R --reseat --seat cx --seat cxn 2>&1)
echo "$out" | grep -q '^RESEAT cx: codex 44444444-4444-4444-8444-444444444444 (-a never -s danger-full-access; marker master, recorded) in cx-maintainer' && ok "a live seat is planned for a reseat, with the pane that holds it" || bad "reseat plan: $out"
echo "$out" | grep -q '^OK cxn: started by rescue' && ok "a seat rescue started is left alone, so a reseat can be run again" || bad "reseat twice: $out"
[ ! -s "$T/launched" ] && ok "a reseat plan starts nothing" || bad "reseat plan started something"
{ echo "800 x"; echo "900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server"; } > "$T/ps.out"
sed -i '' 's/^800 x$/801 x/' "$T/ps.out"
out=$(R --reseat --seat cx --stagger 0 2>&1); echo "$out" | grep -q '^UNRESOLVED cx: no pane in cx-maintainer holds' && ok "a seat whose pane does not hold its thread is not touched" || bad "no holder: $out"
{ echo "800 /x/codex resume 44444444-4444-4444-8444-444444444444"; } > "$T/ps.out"
echo "-- one --apply at a time, and a run kills only a session it made"
mkdir -p "$T/keep"; for f in ps.out psE.out lsof.out; do cp "$T/$f" "$T/keep/$f" 2>/dev/null || : > "$T/keep/$f"; done # put back below
LK=$T/state/apply.lock; ME="$$ $(/bin/ps -o lstart= -p $$ | sed -e 's/^ *//' -e 's/ *$//')"
CLE='ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=cl GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x'
reset_live; : > "$T/ps.out"; printf '%s' "$CLE" > "$T/psE.out"; mkdir "$LK"; echo "$ME" > "$LK/holder"
out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "^LOCKED, nothing was done: another rescue --apply is running (pid $$, " && [ ! -s "$T/launched" ] && [ "$(cat "$LK/holder")" = "$ME" ] && ok "a second --apply refuses while the first holds the lock, and starts nothing" || bad "lock: $rc $out"
echo "$(R --seat cl 2>&1)" | grep -q '^RESUME cl' && ok "a plan, which starts nothing, still runs beside it" || bad "plan under lock"
out=$(R --apply --break-stale-lock --seat cl 2>&1); [ $? -eq 1 ] && echo "$out" | grep -q '^LOCKED, nothing' && [ "$(cat "$LK/holder")" = "$ME" ] && ok "--break-stale-lock never breaks a lock whose holder runs" || bad "break live: $out"
echo "999999 Thu Jan  1 00:00:00 2026" > "$LK/holder"
out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q '^STALE LOCK, nothing was done: .* names pid 999999 .*--break-stale-lock' && [ ! -s "$T/launched" ] && [ -d "$LK" ] && ok "a lock whose holder is gone is reported and refused, never broken silently" || bad "stale: $rc $out"
R --seat cl --break-stale-lock >/dev/null 2>&1; [ $? -eq 2 ] && ok "--break-stale-lock goes only with --apply" || bad "break usage"
rm -f "$T"/has.*; printf 'cp "%s" "%s"\n' "$LK/holder" "$T/held" > "$T/onhas2"
out=$(R --apply --break-stale-lock --seat cl 2>&1); rm -f "$T/onhas2"
echo "$out" | grep -q '^STALE LOCK BROKEN: pid 999999 ' && echo "$out" | grep -q '^RESUMED cl: .* at [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$' && ls -d "$LK".stale-* >/dev/null 2>&1 \
  && ok "--break-stale-lock breaks exactly that lock, keeps it aside, and the run goes on; RESUMED says when the seat was started" || bad "break: $out"
h=$(cut -d' ' -f1 "$T/held" 2>/dev/null); [ -n "$h" ] && [ "$h" != 999999 ] && [ "$h" != $$ ] && [ ! -e "$LK" ] && ok "the run held its own lock while it started the seat, and let it go at the end" || bad "held: $(cat "$T/held" 2>/dev/null) $(ls "$T/state")"
reset_live; : > "$T/ps.out"; rm -f "$T"/has.*; touch "$T/newsess-taken"
out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/newsess-taken"
[ $rc -eq 1 ] && echo "$out" | grep -q '^FAILED cl: its session cl-maintainer exists already: something else started it after the check, and it is left alone' && ! grep -q kill-session "$T/tmux.log" \
  && ok "a session that exists when the run starts the seat is not the run's own, so it is never killed" || bad "taken: $rc $out $(grep kill "$T/tmux.log")"
reset_live; : > "$T/ps.out"; touch "$T/optfail"
out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/optfail"
[ $rc -eq 1 ] && echo "$out" | grep -q '^FAILED cl: tmux could not start it' && grep -q 'kill-session -t =cl-maintainer' "$T/tmux.log" && ok "a session the run made itself and could not finish is killed, so the next run resumes the seat" || bad "own kill: $rc $out"

echo "-- just before its start a seat is read again: with the stagger the plan is minutes old"
reset_live; : > "$T/ps.out"; rm -f "$T"/has.*; printf 'echo cl-maintainer >> "%s"\n' "$T/live" > "$T/onhas2"
out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/onhas2"
[ $rc -eq 1 ] && echo "$out" | grep -q '^FAILED cl: its session cl-maintainer appeared after the plan' && ! grep -qE 'new-session|kill-session' "$T/tmux.log" && ok "a session that appeared after the plan is left alone: not started again, not killed" || bad "appeared: $rc $out"
reset_live; : > "$T/ps.out"; rm -f "$T"/has.*; printf 'echo "4242 claude" > "%s"; printf "p4242\\nfcwd\\nn%s\\n" > "%s"\n' "$T/ps.out" "$T/w/cl" "$T/lsof.out" > "$T/onhas2"
out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/onhas2"; : > "$T/ps.out"; : > "$T/lsof.out"
[ $rc -eq 1 ] && echo "$out" | grep -q "^FAILED cl: a claude process runs in $T/w/cl now" && ! grep -q new-session "$T/tmux.log" && ok "so is a seat whose harness started in its folder after the plan" || bad "running now: $rc $out"
reset_live; printf '9 /x/claude --resume 22222222-2222-4222-8222-222222222222\n' > "$T/ps.out"
out=$(R --apply --seat cl 2>&1); rc=$?; : > "$T/ps.out"
[ $rc -eq 1 ] && echo "$out" | grep -q '^FAILED cl: a process holds its session 22222222-2222-4222-8222-222222222222 now' && ! grep -q new-session "$T/tmux.log" && ok "and so is a seat whose session a process holds at its start" || bad "held now: $rc $out"
echo "-- whether a harness works in a seat's folder: lsof's answer counts, never its silence or its failure"
# a live Claude is in cl's folder; lsof cannot say so
for f in '1' '1\nlsof: can not read a process' '2'; do
  reset_live; echo "4242 claude" > "$T/ps.out"; printf "$f\n" > "$T/lsof.fail-run"
  out=$(R --apply --seat cl 2>&1); rc=$?; w=$(printf "$f" | sed -n 2p)
  [ $rc -eq 3 ] && echo "$out" | grep -qF "UNRESOLVED cl: could not tell whether a process runs in $T/w/cl (lsof exited $(printf "$f" | head -1) with no output${w:+: $w}), so it is not started this run" && ! grep -q new-session "$T/tmux.log" \
    && ok "a live Claude with lsof exiting $(printf "$f" | head -1) and no output${w:+, with stderr} is never doubled: no start" || bad "run fail $f: $rc $out"
done
reset_live; echo "4242 claude" > "$T/ps.out"; printf '1\n' > "$T/lsof.fail-run"; printf 'p4242\nfcwd\nn%s\n' "$T/w/cl" > "$T/lsof.fail-run.out"
echo "$(R --seat cl 2>&1)" | grep -q "^RUNNING cl: a claude process is in $T/w/cl" && ok "lsof's exit 1 with output (a listed pid just exited) still answers: the seat is RUNNING" || bad "just exited, here"
# The reviewer's witness: two live claude processes, lsof reads one (in another folder), fails on the other, and exits 1. No start.
reset_live; printf '4242 claude\n4243 claude\n' > "$T/ps.out"; printf '1\nlsof: can not read process 4243\n' > "$T/lsof.fail-run"; printf 'p4242\nfcwd\nn/elsewhere\n' > "$T/lsof.fail-run.out"
out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -qF "UNRESOLVED cl: could not tell whether a process runs in $T/w/cl (lsof exited 1 without the folder in its output: lsof: can not read process 4243), so it is not started this run" && ! grep -q new-session "$T/tmux.log" \
  && ok "partial output that misses the folder, with one process unreadable, is could-not-tell: no start" || bad "witness plan: $rc $out"
reset_live; printf '4343 codex\n4344 codex\n' > "$T/ps.out"; printf '1\nlsof: can not read process 4344\n' > "$T/lsof.fail-run"; printf 'p4343\nfcwd\nn/elsewhere\n' > "$T/lsof.fail-run.out"
out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -qF "FAILED cl: whether a claude or codex process works in $T/w/cl cannot be read just before the start (lsof exited 1 without the folder in its output: lsof: can not read process 4344); it was not started" && ! grep -q new-session "$T/tmux.log" \
  && ok "the same partial answer at the last check before a Claude start: no start" || bad "witness final: $rc $out"
reset_live; printf '4242 claude\n' > "$T/ps.out"; printf '0\nlsof: WARNING: can not stat a mount\n' > "$T/lsof.fail-run"; printf 'p4242\nfcwd\nn/elsewhere\n' > "$T/lsof.fail-run.out"
out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -qF "could not tell whether a process runs in $T/w/cl (lsof exited 0 without the folder in its output: lsof: WARNING: can not stat a mount)" && ! grep -q new-session "$T/tmux.log" \
  && ok "exit 0 with a line on stderr is not a clean answer either: no start" || bad "exit0 stderr: $rc $out"
rm -f "$T/lsof.fail-run" "$T/lsof.fail-run.out"; reset_live; printf '4242 claude\n' > "$T/ps.out"; printf 'p4242\nfcwd\nn/elsewhere\n' > "$T/lsof.out"
echo "$(R --seat cl 2>&1)" | grep -q '^RESUME cl' && ok "only a clean answer (exit 0, nothing on stderr) naming other folders lets the seat be planned" || bad "clean idle: $(R --seat cl 2>&1)"
: > "$T/lsof.out"; printf '4242 claude\n' > "$T/ps.out"; printf '1\nlsof: can not read process 4243\n' > "$T/lsof.fail-run"; printf 'p4242\nfcwd\nn%s\n' "$T/w/cl" > "$T/lsof.fail-run.out"
echo "$(R --seat cl 2>&1)" | grep -q "^RUNNING cl: a claude process is in $T/w/cl" && ok "output naming the folder proves RUNNING, whatever the exit status and stderr" || bad "target with error"
rm -f "$T/lsof.fail-run" "$T/lsof.fail-run.out"
reset_live; echo "4343 codex" > "$T/ps.out"; printf 'p4343\nfcwd\nn%s\n' "$T/w/cl" > "$T/lsof.out"
out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "^FAILED cl: a claude or codex process works in $T/w/cl just before the start; it was not started" && ! grep -q new-session "$T/tmux.log" && ok "the last check before a Claude start finds any harness in its folder, Codex too: no start" || bad "final guard: $rc $out"
reset_live; printf '1\nlsof: can not read a process\n' > "$T/lsof.fail-run"
out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/lsof.fail-run"
[ $rc -eq 1 ] && echo "$out" | grep -qF "FAILED cl: whether a claude or codex process works in $T/w/cl cannot be read just before the start (lsof exited 1 with no output: lsof: can not read a process); it was not started" && ! grep -q new-session "$T/tmux.log" && ok "and if lsof cannot say, there is no start either" || bad "final guard fail: $rc $out"
: > "$T/ps.out"; : > "$T/lsof.out"
for f in ps.out psE.out lsof.out; do cp "$T/keep/$f" "$T/$f"; done; reset_live

echo "-- LIMITED: a Claude seat at the usage-limit menu is read from its screen, never answered"
grep -q 'send-keys' "$HERE/rescue.sh" && bad "rescue.sh can send a key to a seat" || ok "rescue.sh has no send-keys anywhere: it reads screens, never answers them"
mkdir -p "$T/keep"; for f in ps.out psE.out lsof.out; do cp "$T/$f" "$T/keep/$f" 2>/dev/null || : > "$T/keep/$f"; done
LM=$'  Claude usage limit reached.\n  1. Switch to usage credits\n  2. Stop and wait for limit to reset\n'
reset_live; rm -f "$T/screen" "$T/capfail"; echo cl-maintainer >> "$T/live"
echo "$(R --seat cl 2>&1)" | grep -qxF 'LIVE cl (cl-maintainer)' && ok "control: a Claude seat with an ordinary screen reads LIVE" || bad "limit control: $(R --seat cl 2>&1)"
printf '%s' "$LM" > "$T/screen"; out=$(R --seat cl 2>&1)
echo "$out" | grep -q '^LIMITED cl (cl-maintainer): at the usage-limit menu' && ! echo "$out" | grep -q '^LIVE cl' && echo "$out" | grep -q 'limited 1,' && ! grep -q 'send-keys' "$T/tmux.log" \
  && ok "positive control: the menu on its screen makes it LIMITED, counted, and no key is sent" || bad "limited: $out"
: > "$T/tmux.log"; printf '%s' "$LM" > "$T/screen"; echo "9 /x/claude --resume 22222222-2222-4222-8222-222222222222" > "$T/ps.out"; printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=cl GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x' > "$T/psE.out"
out=$(R --check --seat cl 2>&1); echo "$out" | grep -q '^WRONG cl (claude): .*LIMITED: at the usage-limit menu' && ! grep -q 'send-keys' "$T/tmux.log" && ok "--check names it WRONG: LIMITED" || bad "check limited: $out"
echo cx-maintainer >> "$T/live"; echo "$(R --seat cx 2>&1)" | grep -qxF 'LIVE cx (cx-maintainer)' && ok "a Codex seat is not judged by this menu" || bad "codex limited: $(R --seat cx 2>&1)"
touch "$T/capfail"; echo "$(R --seat cl 2>&1)" | grep -q '^LIVE cl (cl-maintainer): its screen cannot be read' && ok "a screen that cannot be read is said so, never taken as clear" || bad "capfail: $(R --seat cl 2>&1)"; rm -f "$T/capfail"
# the order: in a chart that lists cx before cl, a LIMITED cl is restarted first
printf '{"seats":[%s,%s]}' "$(row cx cx codex h cx-maintainer "$T/w/cx")" "$(row cl cl claude h cl-maintainer "$T/w/cl")" > "$T/chart-xl.json"
reset_live; printf 'cx-maintainer\ncl-maintainer\n' > "$T/live"; printf 'cx-maintainer|%%8|800||codex\ncl-maintainer|%%3|9||claude\n' > "$T/panes"
printf '800 /x/codex resume 44444444-4444-4444-8444-444444444444\n9 /x/claude --resume 22222222-2222-4222-8222-222222222222\n' > "$T/ps.out"
rm -f "$T/screen"; out=$("$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-xl.json" --reseat 2>&1)
echo "$out" | grep -qx 'ORDER: cx cl ' && ok "control: with no seat at the menu, the starts follow the plan" || bad "order control: $out"
printf '%s' "$LM" > "$T/screen"; out=$("$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-xl.json" --reseat 2>&1)
echo "$out" | grep -q '^LIMITED cl: at the usage-limit menu; it is restarted first' && echo "$out" | grep -qx 'ORDER: cl cx ' && ok "positive control: a LIMITED seat is restarted first" || bad "order: $out"
echo "-- the account, from the keychain login in a fresh process; and after every Claude restart, no usage-limit menu"
cat > "$T/bin/claude-auth" <<S
#!/bin/bash
[ "\$1 \$2 \$3" = "auth status --json" ] || exit 9
[ -z "\${ANTHROPIC_API_KEY:-}\${CLAUDE_CONFIG_DIR:-}" ] || { echo '{"loggedIn":false}'; exit 0; } # an inherited setting would change the answer
cat "$T/auth.json" 2>/dev/null
S
chmod +x "$T/bin/claude-auth"; export ZEO_RESCUE_CLAUDE_AUTH=$T/bin/claude-auth
printf '{"loggedIn":true,"email":"someone@example.org","orgId":"org-test","orgName":"Example Org","accessToken":"tok-FAKE-for-tests"}' > "$T/auth.json"
[ "$(ANTHROPIC_API_KEY=x "$T/bin/claude-auth" auth status --json)" = '{"loggedIn":false}' ] && ok "control: the auth stub answers differently when a caller's setting leaks into it" || bad "auth stub"
reset_live; rm -f "$T/screen"; : > "$T/ps.out"; printf '%s' "$CLE" > "$T/psE.out"
out=$(ANTHROPIC_API_KEY=x R --apply --seat cl --expect-org 'Example Org' 2>&1); rc=$?
echo "$out" | grep -qxF 'ACCOUNT: logged in, email domain example.org, organization Example Org' && ! echo "$out" | grep -qE 'someone|tok-FAKE|org-test' && echo "$out" | grep -q '^RESUMED cl' && echo "$out" | grep -q '^SEAT OK cl: no usage-limit menu' \
  && ok "the login is read in a fresh process; only the email domain and organization are printed; the seat is checked after its restart" || bad "account: $rc $out"
reset_live; : > "$T/ps.out"; out=$(R --apply --seat cl --expect-org 'Other Org' 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -qF "ACCOUNT REFUSED, nothing was stopped or started: the login is organization 'Example Org', not 'Other Org'" && ! grep -qE 'new-session|respawn-pane' "$T/tmux.log" \
  && ok "positive control: a login of another organization is refused before any seat is stopped or started" || bad "account refused: $rc $out"
reset_live; : > "$T/auth.json"; out=$(R --apply --seat cl --expect-org 'Example Org' 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q '^ACCOUNT UNKNOWN' && ! grep -q new-session "$T/tmux.log" && ok "a login that cannot be read is refused when an organization is expected" || bad "account unknown: $rc $out"
out=$(R --seat cl --expect-org 'Example Org' 2>&1); [ $? -eq 2 ] && ok "--expect-org goes only with --apply" || bad "expect usage"
printf '#!/bin/bash\nsleep 30\n' > "$T/bin/claude-hang"; chmod +x "$T/bin/claude-hang"; reset_live; s0=$(date +%s)
out=$(ZEO_RESCUE_AUTH_WAIT=1 ZEO_RESCUE_CLAUDE_AUTH=$T/bin/claude-hang R --apply --seat cl --expect-org 'Example Org' 2>&1); rc=$?; s1=$(date +%s)
[ $rc -eq 1 ] && echo "$out" | grep -q '^ACCOUNT UNKNOWN' && [ $((s1 - s0)) -lt 10 ] && ! grep -q new-session "$T/tmux.log" && ok "a claude auth status that hangs is cut off after ZEO_RESCUE_AUTH_WAIT and counts as unreadable" || bad "auth hang: $rc $((s1 - s0))s $out"
printf '{"loggedIn":true,"email":"someone@example.org","orgName":"Example Org"}' > "$T/auth.json"
# every Claude seat is checked, not only the first: a second seat comes up at the menu
mkdir -p "$T/w/cl3"; d3=$T/projects/$(enc "$T/w/cl3"); mkdir -p "$d3"; echo '{"permissionMode":"auto"}' > "$d3/12121212-1212-4121-8121-121212121212.jsonl"
printf '{"seats":[%s,%s]}' "$(row cl cl claude h cl-maintainer "$T/w/cl")" "$(row cm cm claude h cm-maintainer "$T/w/cl3")" > "$T/chart-2c.json"
cp "$T/state/seat-markers" "$T/markers.keep"; echo 'cm master' >> "$T/state/seat-markers"
printf 'case "$1" in *12121212-1212-4121-8121-121212121212*) printf "%%s" "%s" > "%s";; esac\n' "$LM" "$T/screen" > "$T/onrespawn"
reset_live; rm -f "$T/screen"; : > "$T/ps.out"; printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=cl ZMAIL_INSTANCE=cm GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x' > "$T/psE.out"
out=$("$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-2c.json" --apply --expect-org 'Example Org' 2>&1); rc=$?
echo "$out" | grep -q '^SEAT OK cl: no usage-limit menu' && echo "$out" | grep -q '^STOPPED: cm is at the usage-limit menu 0 s after its restart' && [ $rc -eq 1 ] \
  && ok "positive control: the second seat at the menu stops the run; every seat is checked, not only the first" || bad "every seat: $rc $out"
rm -f "$T/onrespawn" "$T/screen"; cp "$T/markers.keep" "$T/state/seat-markers"; unset ZEO_RESCUE_CLAUDE_AUTH
echo "-- --relogin: the account move, every live Claude seat in place, one at a time, idle first, never the Architect"
printf '{"seats":[%s,%s,%s,%s]}' "$(row cl cl claude h cl-maintainer "$T/w/cl")" "$(row cm cm claude h cm-maintainer "$T/w/cl3")" "$(row arch arch claude h arch-s "$T/w/cl2")" "$(row cx cx codex h cx-maintainer "$T/w/cx")" > "$T/chart-rl.json"
cp "$T/state/seat-markers" "$T/markers.keep"; echo 'cm master' >> "$T/state/seat-markers"; echo 'You were restarted on a new login for a test.' > "$T/rnote"
RL() { ZEO_RESCUE_ARCHITECT_SEAT=arch "$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-rl.json" "$@" 2>&1; }
rlreset() { reset_live; rm -f "$T/screen" "$T/onrespawn"; printf 'cl-maintainer\ncm-maintainer\narch-s\ncx-maintainer\n' > "$T/live"
  printf 'cl-maintainer|%%3|9||claude\ncm-maintainer|%%4|10||claude\narch-s|%%5|11||claude\ncx-maintainer|%%8|800||codex\n' > "$T/panes"
  printf '9 /x/claude --resume 22222222-2222-4222-8222-222222222222\n10 /x/claude --resume 12121212-1212-4121-8121-121212121212\n11 /x/claude --resume 33333333-3333-4333-8333-333333333333\n800 /x/codex resume 44444444-4444-4444-8444-444444444444\n' > "$T/ps.out"; : > "$T/lsof.out"; : > "$T/moves"; }
F2=$T/projects/$(enc "$T/w/cl")/22222222-2222-4222-8222-222222222222.jsonl F12=$d3/12121212-1212-4121-8121-121212121212.jsonl
rlreset; touch -t 202601010000 "$F12"; touch -t 202601020000 "$F2"; out=$(RL --relogin --note-file "$T/rnote")
echo "$out" | grep -qxF 'EXCEPT arch: left out of this run' && echo "$out" | grep -q '^RESEAT cl: claude' && echo "$out" | grep -q '^RESEAT cm: claude' && ! echo "$out" | grep -qE '(RESEAT|OK|LIVE|DOWN) (arch|cx)' && echo "$out" | grep -qx 'ORDER: cm cl ' \
  && ok "a relogin plan takes every live Claude seat, leaves the Architect and every Codex seat out, and puts the longest idle first" || bad "relogin plan: $out"
touch -t 202601030000 "$F12"; echo "$(RL --relogin --note-file "$T/rnote")" | grep -qx 'ORDER: cl cm ' && ok "positive control: when the other seat has been idle longer, it goes first" || bad "relogin order flip"
printf '%s' "$LM" > "$T/screen"; out=$(RL --relogin --note-file "$T/rnote"); rm -f "$T/screen"
echo "$out" | grep -q '^LIMITED cl: at the usage-limit menu; it is restarted first' && echo "$out" | grep -qE '^ORDER: (cl cm|cm cl) $' && ok "seats at the usage-limit menu are read and flagged in a relogin plan" || bad "relogin limited: $out"
[ "$(RL --relogin 2>&1 >/dev/null; echo $?)" = 2 ] && echo "$(RL --relogin)" | grep -q 'needs --note-file' && ok "--relogin needs --note-file" || bad "relogin note"
out=$(RL --relogin --note-file "$T/rnote" --apply); [ $? -eq 2 ] && echo "$out" | grep -q 'needs --expect-org' && ok "--relogin --apply needs --expect-org" || bad "relogin org: $out"
out=$("$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-rl.json" --relogin --note-file "$T/rnote" 2>&1); [ $? -eq 2 ] && echo "$out" | grep -q "needs the Architect's seat id" && ok "positive control: with no Architect seat id known, --relogin refuses rather than risk restarting the Architect" || bad "relogin arch: $out"
rlreset; printf 'cl %s carry-plain\n' "$T/w/elsewhere" > "$T/moves"; out=$(RL --relogin --note-file "$T/rnote")
echo "$out" | grep -q '^RESEAT cl:' && ! echo "$out" | grep -qE '^MOVE cl|carry' && ok "a relogin never acts on a pending folder-moves line: it is in place" || bad "relogin moves: $out"
rlreset; grep -v '^cm-maintainer$' "$T/live" > "$T/live.x" && mv "$T/live.x" "$T/live"; out=$(RL --relogin --note-file "$T/rnote")
echo "$out" | grep -q '^DOWN cm: an in-place restart restarts only live seats' && ! echo "$out" | grep -q '^RESUME cm' && ok "a seat that is down is DOWN, not resumed by a relogin" || bad "relogin down: $out"
# NEEDS-LOGIN: a Claude seat on another host has its own login; a relogin names it with the line to run there
rlreset; out=$(RL --relogin --note-file "$T/rnote"); echo "$out" | grep -q '^NEEDS-LOGIN' && bad "needs-login control: $out" || ok "control: with no Claude seat on another host, no NEEDS-LOGIN line"
printf '{"seats":[%s,%s,%s,%s]}' "$(row cl cl claude h cl-maintainer "$T/w/cl")" "$(row far far claude other-host far-s "$T/w/far")" "$(row farx farx codex other-host farx-s "$T/w/farx")" "$(row odd odd claude other-host 'odd;s' "$T/w/odd")" > "$T/chart-far.json"
out=$(ZEO_RESCUE_ARCHITECT_SEAT=arch "$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-far.json" --relogin --note-file "$T/rnote" 2>&1)
echo "$out" | grep -qxF "NEEDS-LOGIN other-host far: this host's login does not reach it. On other-host the operator runs: tmux -L zeo2 attach -t '=far-s'   then types /login in that pane, and detaches with C-b d" \
  && ! echo "$out" | grep -qE 'NEEDS-LOGIN [^ ]+ farx|RESEAT far|RESUME far' && echo "$out" | grep -q 'needs login on other hosts 2,' \
  && ok "positive control: a Claude seat on another host is named NEEDS-LOGIN with the exact line, never restarted from here; a Codex seat there is not listed" || bad "needs-login: $out"
echo "$out" | grep -q "^NEEDS-LOGIN other-host odd: .*not a plain name, so no line is given" && ok "a chart session that is not a plain name gets no line to run" || bad "needs-login odd: $out"
# apply: one seat at a time (each stop is followed by that seat's start before the next stop); the stub's stop ends the seat's process
export ZEO_RESCUE_CLAUDE_AUTH=$T/bin/claude-auth; printf '{"loggedIn":true,"email":"someone@example.org","orgName":"Example Org"}' > "$T/auth.json"
printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=cl ZMAIL_INSTANCE=cm GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x' > "$T/psE.out"
rlonr() { printf 'case "$1" in *"-t %%3 "*"sleep 3600"*) sed -i "" "/2222-4222/d" "%s";; *"-t %%4 "*"sleep 3600"*) sed -i "" "/1212-4121/d" "%s";; esac\n' "$T/ps.out" "$T/ps.out" > "$T/onrespawn"; }
seq_of() { grep 'respawn-pane' "$T/tmux.log" | sed -E 's/.* -t (%[0-9]+) .*(sleep 3600|seat-exec\.sh).*/\1 \2/; s/seat-exec\.sh/start/; s/sleep 3600/stop/' | tr '\n' ' '; }
rlreset; touch -t 202601010000 "$F12"; touch -t 202601020000 "$F2"; rlonr; out=$(RL --relogin --note-file "$T/rnote" --apply --expect-org 'Example Org'); rc=$?
s=$(seq_of); [ $rc -eq 0 ] && [ "$s" = '%4 stop %4 start %3 stop %3 start ' ] && echo "$out" | grep -q '^SEAT OK cm' && echo "$out" | grep -q '^SEAT OK cl' && ! grep -qE ' -t (%5|%8) ' "$T/tmux.log" && ! grep -q 'kill' "$T/tmux.log" \
  && grep -q 'new Claude login' "$T/state/prompts/cm.txt" && grep -q 'new login for a test' "$T/state/prompts/cm.txt" \
  && ok "relogin --apply stops and starts one seat at a time, idle first, checks each, never touches the Architect or a Codex seat, and tells each why" || bad "relogin apply: $rc [$s] $out"
rlreset; rlonr; out=$("$HERE/rescue.sh" --host h --stagger 0 --chart "$T/chart-rl.json" --reseat --harness claude --except arch --apply 2>&1)
s=$(seq_of); case "$s" in *stop*stop*start*start*) ok "positive control: a plain reseat stops every seat before it starts any";; *) bad "reseat order control: [$s] $out";; esac
rm -f "$T/onrespawn"; cp "$T/markers.keep" "$T/state/seat-markers"; unset ZEO_RESCUE_CLAUDE_AUTH
rm -f "$T/screen"; for f in ps.out psE.out lsof.out; do cp "$T/keep/$f" "$T/$f"; done; reset_live

echo "-- a stuck process and the daemon"
reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
out=$(R --reseat --apply --seat cx 2>&1); rc=$?
echo "$out" | grep -q '^FAILED cx: its old process would not stop' && ok "a process that will not stop is not joined by a second one" || bad "stuck: $out"
[ $rc -eq 1 ] && ok "that exits 1" || bad "stuck exit $rc"
grep -q 'seat-exec.sh' "$T/launched" && bad "started over a live process" || ok "nothing started over it"
cat > "$T/bin/ps" <<S
#!/bin/bash
case "\$1" in
  -Ewwp) if [ -s "$T/psE.out" ]; then cat "$T/psE.out"; else echo "$GOOD"; fi; exit 0;;
  -axo) [ ! -f "$T/ps.fail" ] || exit 2; case "\$2" in *ppid*) cat "$T/ps.tree" 2>/dev/null; exit 0;; esac ;;
esac
if [ -f "$T/ps.seen" ]; then cat "$T/ps.after"; else touch "$T/ps.seen"; cat "$T/ps.out"; fi
exit 0
S
printf 'p900\nfcwd\nn/\nf31\nn%s\n' "$T/sess/rollout-2026-11-09T01-02-03-44444444-4444-4444-8444-444444444444.jsonl" > "$T/lsof.daemon"
reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
echo "900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server" >> "$T/ps.out"
echo "900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server" > "$T/ps.after"
out=$(R --reseat --apply --seat cx 2>&1)
echo "$out" | grep -q '^DAEMON STOP: pid 900, /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server$' && ok "the daemon stops when no seat is attached and it holds only the threads of seats this run stopped, each pid named" || bad "daemon: $out"
grep -qx '900' "$T/kills" && ok "by exact pid" || bad "kills: $(cat "$T/kills" 2>/dev/null)"
grep -qx -- '-9 900' "$T/kills" && ok "and by SIGKILL when it ignores SIGTERM" || bad "kill -9: $(cat "$T/kills" 2>/dev/null)"
d=$(grep -n 'seat-exec' "$T/tmux.log" | head -1 | cut -d: -f1); [ -n "$d" ] && ok "the seat restarts after the daemon stops" || bad "no restart: $out"
rm -f "$T/ps.seen"; reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
echo "901 /x/codex resume -a never -s danger-full-access 01010101-0101-4101-8101-010101010101 x" >> "$T/ps.after"
out=$(R --reseat --apply --seat cx 2>&1)
echo "$out" | grep -q 'DAEMON LEFT: 1 Codex seats' && ok "the daemon stays while another seat is attached" || bad "daemon left: $out"
[ ! -e "$T/kills" ] && ok "and nothing is killed" || bad "killed: $(cat "$T/kills")"
rm -f "$T/ps.seen"
# The daemon goes only when every thread it holds open is a seat this run stopped, and only when that can be read (the Architect, 9 Nov 11:28Z)
dtest() { # dtest LSOF-DAEMON-FILE-OR-none: one reseat of cx with the daemon at pid 900; $out holds the output
  rm -f "$T/ps.seen"; reset_live; echo cx-maintainer >> "$T/live"; echo 'cx-maintainer|%8|800||codex' > "$T/panes"
  echo "900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server" > "$T/ps.after"
  if [ "$1" = none ]; then rm -f "$T/lsof.daemon"; else printf "$1" > "$T/lsof.daemon"; fi
  out=$(R --reseat --apply --seat cx 2>&1)
}
dtest "p900\nfcwd\nn/\nf31\nn$T/sess/rollout-2026-11-09T01-02-03-01010101-0101-4101-8101-010101010101.jsonl\n"
echo "$out" | grep -q '^DAEMON LEFT: pid 900 holds thread 01010101-0101-4101-8101-010101010101 open, which is no seat this run stopped, so no daemon was stopped' && [ ! -e "$T/kills" ] && ok "a daemon holding another seat's thread is left, and nothing is killed" || bad "daemon other: $out $(cat "$T/kills" 2>/dev/null)"
dtest none
echo "$out" | grep -q '^DAEMON LEFT: which seats pid 900 serves cannot be read, so no daemon was stopped' && [ ! -e "$T/kills" ] && ok "a daemon whose open files cannot be read is left, and the run says so" || bad "daemon unread: $out"
dtest "p900\nfcwd\nn/\n"; out2=$out; ZEO_RESCUE_LSOF=$T/no-lsof dtest "p900\nfcwd\nn/\n"
echo "$out" | grep -q '^DAEMON LEFT: which seats pids 900 serve cannot be read (no lsof), so no daemon was stopped' && [ ! -e "$T/kills" ] && ok "and so is one when there is no lsof" || bad "daemon no lsof: $out"
echo "$out2" | grep -q '^DAEMON STOP: pid 900, ' && ok "a daemon that holds no thread open goes" || bad "daemon none held: $out2"
rm -f "$T/ps.seen"; reset_live; echo cx-maintainer >> "$T/live"; echo 'cx-maintainer|%8|800||codex' > "$T/panes"
printf '900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server\n800 /x/codex resume --no-daemon 44444444-4444-4444-8444-444444444444\n' > "$T/ps.after"
printf "p900\nfcwd\nn/\nf31\nn$T/sess/rollout-2026-11-09T01-02-03-44444444-4444-4444-8444-444444444444.jsonl\n" > "$T/lsof.daemon"; out=$(R --reseat --apply --seat cx 2>&1)
echo "$out" | grep -q '^FAILED cx: its old process would not stop' && echo "$out" | grep -q '^DAEMON LEFT: pid 900 holds thread 44444444-4444-4444-8444-444444444444 open, which is no seat this run stopped' && [ ! -e "$T/kills" ] && ok "a seat whose old process would not stop is not this run's to free: its daemon is left" || bad "daemon stuck seat: $out"
echo "900 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server" > "$T/ps.after"
printf 'p900\nfcwd\nn/\n' > "$T/lsof.daemon"; rm -f "$T/ps.seen"

echo "-- two writers: a thread something still holds"
reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
echo 900 > "$T/lsof.held"
out=$(R --reseat --apply --seat cx 2>&1); rc=$?
echo "$out" | grep -q '^FAILED cx: pid 900 still holds its rollout, so it was not started' && ok "a live seat is not started while the daemon holds its thread" || bad "held: $out"
[ $rc -eq 1 ] && ok "that exits 1" || bad "held exit $rc"
grep -q 'seat-exec.sh' "$T/launched" && bad "started beside the daemon" || ok "and nothing was started beside it"
grep -q -- "-t -- $T/sess/full.jsonl" "$T/lsof.args" && ok "the question is asked of the seat's own rollout" || bad "lsof args: $(cat "$T/lsof.args" 2>/dev/null)"
rm -f "$T/ps.seen"; reset_live
out=$(R --apply --seat cx 2>&1)
echo "$out" | grep -q '^FAILED cx: pid 900 still holds' && ! grep -q new-session "$T/launched" && ok "a dead seat is held to the same test" || bad "held dead seat: $out"
rm -f "$T/lsof.held" "$T/ps.seen"

echo "-- an inspection that fails is never read as idle: no start, no carry"
# lsof's exit 1 with nothing anywhere is its own "no match"; any other exit, or anything on stderr, is a failed question.
for f in '2' '1\nlsof: status error on the rollout'; do
  rm -f "$T/ps.seen"; reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
  printf "$f\n" > "$T/lsof.fail-t"; out=$(R --reseat --apply --seat cx 2>&1); rc=$?
  echo "$out" | grep -q '^FAILED cx: who holds its rollout cannot be read (lsof exited [12].*), so it was not started' && [ $rc -eq 1 ] && ! grep -q 'seat-exec.sh' "$T/launched" \
    && ok "an lsof that fails ($(printf "$f" | head -1 | sed 's/^/exit /')) with no holder printed starts nothing" || bad "lsof fail $f: $rc $out"
done
rm -f "$T/ps.seen"; reset_live; printf '2\n' > "$T/lsof.fail-t"; out=$(R --apply --seat cx 2>&1)
echo "$out" | grep -q '^FAILED cx: who holds its rollout cannot be read' && ! grep -q new-session "$T/launched" && ok "a dead seat is held to the same test" || bad "lsof fail dead: $out"
rm -f "$T/lsof.fail-t" "$T/ps.seen"; reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
printf 'touch %s\n' "$T/ps.fail" > "$T/onstop"; out=$(R --reseat --apply --seat cx 2>&1); rc=$?
echo "$out" | grep -q '^FAILED cx: its old process would not stop' && [ $rc -eq 1 ] && ! grep -q 'seat-exec.sh' "$T/launched" && ok "a process list that cannot be read after the stop is not taken as 'nothing holds it'" || bad "ps fail: $rc $out"
rm -f "$T/onstop" "$T/ps.fail" "$T/ps.seen"

echo "-- a first seat that fails its proof"
reset_live; echo cx-maintainer >> "$T/live"; echo cxn-s >> "$T/live"
{ echo 'cx-maintainer|%8|800||codex'; echo 'cxn-s|%2|802||codex'; } > "$T/panes"
{ echo "800 /x/codex resume 44444444-4444-4444-8444-444444444444"; echo "802 /x/codex resume 77777777-7777-4777-8777-777777777777"; } > "$T/ps.out"; : > "$T/ps.after"
printf 'export ZEO_TMUX_SEAT=inactive\nexport ZMAIL_INSTANCE=seat-b\nexport GIT_ALLOW_PROTOCOL=file\n' > "$T/snapwrite"
out=$(R --reseat --apply --seat cx --seat cxn 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'STOPPED: cx did not get its own identity' && ok "the run stops at the failed seat" || bad "stop: $rc $out"
echo "$out" | grep -q '^RECOVERY: 2 seats are down, counting the one that failed' && ok "the output says what is down and what brings it back" || bad "recovery: $out"
[ "$(grep -c seat-exec "$T/launched")" = 1 ] && ok "the next seat stays on its sleep" || bad "others: $(cat "$T/launched")"
s=$(grep -n 'seat-exec' "$T/tmux.log" | head -1 | cut -d: -f1); u=$(grep -n 'respawn-pane -k -t %8 .* sleep 3600' "$T/tmux.log" | tail -1 | cut -d: -f1)
[ -n "$s" ] && [ -n "$u" ] && [ "$s" -lt "$u" ] && ok "the wrong seat is stopped again, not left up" || bad "unseat order: $s $u"
grep -q 'set-option -pu -t %8 @zeo_rescue' "$T/tmux.log" && ok "and loses the mark, so the next run plans it again" || bad "mark: $(cat "$T/tmux.log")"
rm -f "$T/ps.seen"; reset_live
out=$(R --apply --seat cx 2>&1)
grep -q 'kill-session -t =cx-maintainer' "$T/tmux.log" && echo "$out" | grep -q '^RECOVERY: 1 seats' && ok "a seat that was dead goes back to dead, so make rescue can take it" || bad "dead proof: $out"
rm -f "$T/ps.seen"; reset_live; printf 'ZMAIL_INSTANCE=other-seat HOME=/x' > "$T/psE.out"
out=$(R --apply --seat cl 2>&1)
echo "$out" | grep -q '^RECOVERY: 1 seats' && grep -q 'kill-session -t =cl-maintainer' "$T/tmux.log" && ok "the claude proof recovers the same way" || bad "claude recovery: $out"
rm -f "$T/ps.seen"

echo "-- what a restart would cut"
reset_live; echo cx-maintainer >> "$T/live"; { echo 'cx-maintainer|%8|800||codex'; } > "$T/panes"
echo "800 /x/codex resume 44444444-4444-4444-8444-444444444444" > "$T/ps.out"; : > "$T/ps.after"
cat > "$T/ps.tree" <<'E'
  800     1 01:00:00 /x/codex resume 44444444-4444-4444-8444-444444444444
  811   800    02:00 /bin/zsh -c source /x/snap.sh 2>/dev/null || true && setopt X && eval 'make build' < /dev/null
  812   800    02:00 /u/.local/share/zeo/messenger/hooks/runtimes/abc watch
  813   800    02:00 caffeinate -i -t 300
  816   800    59:00 /u/.codex/packages/standalone/releases/0.164.0/bin/codex-code-mode-host
  900     1 03:00:00 /u/.codex/packages/app-server-daemon/releases/1/bin/codex app-server --listen unix://
  914   900    00:30 /bin/sh -c cargo test
  915   900    03:00 /u/.codex/packages/app-server-daemon/releases/1/bin/codex-code-mode-host
E
echo '  Working (9s, esc to interrupt)' > "$T/screen"
out=$(R --reseat --seat cx 2>&1)
echo "$out" | grep -q '^WORK cx: a turn is in progress on its screen' && ok "a turn on the screen is listed" || bad "screen: $out"
echo "$out" | grep -q "^WORK cx: 811 02:00 'make build'" && ok "a tool shell is listed by what it runs" || bad "tool: $out"
echo "$out" | grep -E -q 'WORK.*(hooks|caffeinate|code-mode)' && bad "noise in the list: $out" || ok "mail hooks, caffeinate and the daemon's helper are not work"
echo "$out" | grep -q '^WORK daemon, in .*: 914 00:30 /bin/sh -c cargo test' && ok "a Codex tool under the daemon is listed" || bad "daemon work: $out"
echo "$out" | grep -q '^work: 1 of 1 seats show running work' && ok "and counted" || bad "count: $out"
[ ! -s "$T/launched" ] && ok "listing stops nothing" || bad "the list touched a seat"
rm -f "$T/ps.seen"
out=$(R --reseat --apply --seat cx 2>&1)
w=$(echo "$out" | grep -n '^WORK' | head -1 | cut -d: -f1); r=$(echo "$out" | grep -n '^RESUMED\|^STOPPED\|^FAILED' | head -1 | cut -d: -f1)
[ -n "$w" ] && [ -n "$r" ] && [ "$w" -lt "$r" ] && ok "--apply lists it before it stops anything, so the log keeps what was cut" || bad "order: $w $r"
# A Claude seat's until-loop watcher that started before its last turn is a stale watcher, not work a restart would cut
reset_live; rm -f "$T/ps.seen" "$T/screen"; echo cl-maintainer >> "$T/live"; echo 'cl-maintainer|%3|9||claude' > "$T/panes"
echo "9 /x/claude --resume 22222222-2222-4222-8222-222222222222" > "$T/ps.out"; cp "$T/ps.out" "$T/ps.after"
touch -t "$(date -v-1H +%Y%m%d%H%M)" "$T/projects/$(enc "$T/w/cl")/22222222-2222-4222-8222-222222222222.jsonl"
cat > "$T/ps.tree" <<'E'
    9     1 09:00:00 /x/claude --resume 22222222-2222-4222-8222-222222222222
  921     9 08:00:00 /bin/zsh -c source /x/snap.sh 2>/dev/null || true && eval 'until [ -f /x/flag ]; do sleep 60; done' < /dev/null
  922     9    10:00 /bin/zsh -c source /x/snap.sh 2>/dev/null || true && eval 'until [ -f /y/flag ]; do sleep 5; done' < /dev/null
  923     9 08:00:00 /bin/zsh -c source /x/snap.sh 2>/dev/null || true && eval 'make build' < /dev/null
E
out=$(R --reseat --seat cl 2>&1)
echo "$out" | grep -q "^WORK (stale watcher) cl: 921 08:00:00 'until \[ -f /x/flag \]" && ok "positive control: a watcher running since before the seat's last turn is marked stale" || bad "stale: $out"
echo "$out" | grep -q "^WORK cl: 922 10:00 'until \[ -f /y/flag \]" && ! echo "$out" | grep -q 'stale watcher) cl: 922' && ok "a watcher started after the last turn stays WORK" || bad "fresh watcher: $out"
echo "$out" | grep -q "^WORK cl: 923 08:00:00 'make build'" && ok "an old tool that is not a watcher stays WORK" || bad "old tool: $out"
echo "$out" | grep -q "^work: 1 of 1 seats show running work, and 1 stale watchers" && ok "and the count keeps real work apart from stale watchers" || bad "stale count: $out"
grep -v ' 92[23] ' "$T/ps.tree" > "$T/ps.tree.x" && mv "$T/ps.tree.x" "$T/ps.tree"; rm -f "$T/ps.seen"; out=$(R --reseat --seat cl 2>&1)
echo "$out" | grep -q '^work: 0 of 1 seats show running work, and 1 stale watchers' && ok "a seat with only a stale watcher shows no running work" || bad "only stale: $out"
reset_live; rm -f "$T/ps.seen"; echo cx-maintainer >> "$T/live"; echo 'cx-maintainer|%8|800||codex' > "$T/panes"; echo "800 /x/codex resume 44444444-4444-4444-8444-444444444444" > "$T/ps.out"; : > "$T/ps.after"
printf '  800     1 09:00:00 /x/codex resume 44444444-4444-4444-8444-444444444444\n  931   800 08:00:00 /bin/zsh -c eval %s\n' "'until [ -f /x/flag ]; do sleep 60; done'" > "$T/ps.tree"
out=$(R --reseat --seat cx 2>&1); echo "$out" | grep -q "^WORK cx: 931 08:00:00" && ! echo "$out" | grep -q 'stale watcher' && ok "a Codex seat's lines are unchanged" || bad "codex stale: $out"
rm -f "$T/ps.seen" "$T/screen" "$T/ps.tree" "$T/snapwrite"

echo "-- check"
cat > "$T/bin/ps" <<S
#!/bin/bash
case "\$1" in -Ewwp) cat "$T/psE.out";; -axo) if [ "\$2" = "pid=,ppid=" ] && [ -f "$T/pstree" ]; then cat "$T/pstree"; else cat "$T/ps.out"; fi;; *) cat "$T/ps.out";; esac
exit 0
S
reset_live; echo cx-maintainer >> "$T/live"; echo cl-maintainer >> "$T/live"
{ echo 'cx-maintainer|%8|800|1|codex'; echo 'cl-maintainer|%3|300|1|claude'; } > "$T/panes"
echo "800 /x/codex resume -a never -s danger-full-access -C /w --no-daemon 44444444-4444-4444-8444-444444444444 p" > "$T/ps.out"
printf 'ZMAIL_INSTANCE=cl HOME=/x %s' "$GOOD" > "$T/psE.out"
out=$(R --check --seat cx --seat cl 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q '^OK cx (codex)' && echo "$out" | grep -q '^OK cl (claude)' && ok "seats started right pass" || bad "check: $rc $out"
echo '  Yes, I trust this folder' > "$T/screen"
grep -q '^WRONG cl (claude): waiting at the trust prompt' <<< "$(R --check --seat cl 2>&1)" && ok "a seat at the trust prompt is named, not counted as back" || bad "trust prompt"
rm -f "$T/screen"
printf 'ZMAIL_INSTANCE=cx ' > "$T/psE.out"
echo "800 /x/codex resume 44444444-4444-4444-8444-444444444444 p" > "$T/ps.out"
out=$(R --check --seat cx --seat cl 2>&1); rc=$?
[ $rc -eq 1 ] && ok "a wrong seat exits 1" || bad "check exit $rc"
echo "$out" | grep -q '^WRONG cx (codex): no --no-daemon' && ok "a seat on the daemon is named" || bad "check daemon: $out"
echo "$out" | grep -q '^WRONG cl (claude): environment has another identity' && ok "a seat with another identity is named" || bad "check id: $out"
grep -q '^WRONG cxn (codex): no session' <<< "$(R --check --seat cxn 2>&1)" && ok "a missing seat is named" || bad "check missing"

echo "-- check reads the process and a shell outside the folder, not only the snapshot"
echo "800 /x/codex resume -a never -s danger-full-access -C /w --no-daemon 44444444-4444-4444-8444-444444444444 p" > "$T/ps.out"
C() { R --check --seat cx 2>&1; }
INACTIVE='ZEO_TMUX_SEAT=inactive ZEO_TMUX_ACCOUNT=none GIT_ALLOW_PROTOCOL=file GH_CONFIG_DIR=/x/disabled'
printf 'HOME=/x' > "$T/psE.out"
grep -q '^WRONG cx (codex): process has no seat settings' <<< "$(C)" && ok "a right snapshot does not hide a process without settings" || bad "no settings: $(C)"
: > "$T/seatmark"; printf '%s' "$GOOD" > "$T/psE.out"
grep -q '^WRONG cx (codex): process says master, pane says inactive' <<< "$(C)" && ok "a process that disagrees with its pane is named" || bad "disagree: $(C)"
printf 'ZEO_TMUX_SEAT=inactive ZEO_TMUX_ACCOUNT=none GIT_ALLOW_PROTOCOL=ssh:https:file GH_CONFIG_DIR=/x/disabled' > "$T/psE.out"
grep -q '^WRONG cx (codex): a shell outside its folder has git on' <<< "$(C)" && ok "an inactive seat with git on is named" || bad "git on: $(C)"
printf '%s' "$INACTIVE" > "$T/psE.out"
grep -q '^OK cx (codex)' <<< "$(C)" && ok "an inactive seat with everything off passes" || bad "inactive: $(C)"
touch "$T/plain-c-git-on"
grep -q '^WRONG cx (codex): a shell outside its folder has git on' <<< "$(C)" && ok "both kinds of tool shell are read: a fault only in zsh -c is named" || bad "plain -c: $(C)"
rm -f "$T/plain-c-git-on"
touch "$T/zshenv-resets-gh"
grep -q '^WRONG cx (codex): a shell outside its folder has gh on' <<< "$(C)" && ok "a startup file that turns gh back on is named" || bad "gh on: $(C)"
rm -f "$T/zshenv-resets-gh"
echo master > "$T/seatmark"; printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct GIT_ALLOW_PROTOCOL=file' > "$T/psE.out"
grep -q '^WRONG cx (codex): a shell outside its folder has git off' <<< "$(C)" && ok "a master seat with git off is named" || bad "git off: $(C)"
printf 'ZEO_TMUX_SEAT=master GIT_ALLOW_PROTOCOL=ssh:https:file' > "$T/psE.out"
grep -q '^WRONG cx (codex): a shell outside its folder has no seat author' <<< "$(C)" && ok "a seat that would commit under the wrong author is named" || bad "author: $(C)"
printf '/x/codex resume p You were told ZEO_TMUX_SEAT=inactive and GIT_ALLOW_PROTOCOL=file HOME=/x %s GH_TOKEN=do-not-copy' "$GOOD" > "$T/psE.out"
grep -q '^OK cx (codex)' <<< "$(C)" && ok "prompt text that looks like a setting does not count" || bad "decoy: $(C)"
grep -q 'GH_TOKEN' "$T/probe.env" && bad "a credential reached the probe" || ok "a credential in the process never reaches the probe"
: > "$T/ps.out"; : > "$T/seatmark"

echo "-- a seat moves folder and keeps its thread"
SID=44444444-4444-4444-8444-444444444444
mkdir -p "$T/w/new" "$T/w/newgit" "$T/sessions"; : > "$T/sessions/rollout-$SID.jsonl"; git -C "$T/w/newgit" init -q
cp "$T/sess/full.jsonl" "$T/sess/full.orig"; printf 'cx %s\ncl 22222222-2222-4222-8222-222222222222\n' "$SID" > "$T/pins"
export ZEO_RESCUE_MOVES="$T/moves" ZEO_RESCUE_SESSIONS="$T/sessions" ZEO_RESCUE_CODEX_CONFIG="$T/config.toml"
export ZEO_RESCUE_PINS="$T/pins"
echo master > "$T/seatmark"; printf '%s' "$GOOD" > "$T/psE.out"; : > "$T/ps.out"
printf 'export ZEO_TMUX_SEAT=master\nexport ZMAIL_INSTANCE=cx\nexport GIT_ALLOW_PROTOCOL=ssh:https:file\n' > "$T/snapwrite"
printf '{"cwd":"%s"}\n' "$T/w/new" > "$T/rolladd"; echo 9 > "$T/heldafter"; echo "$T/w/new" > "$T/threadcwd"; echo 0 > "$T/newthreads"
fresh() { reset_live; rm -f "$T/lsof.held"; cp "$T/sess/full.orig" "$T/sess/full.jsonl"; }
printf 'cx %s\n' "$T/w/gone" > "$T/moves"; fresh
grep -q "^UNRESOLVED cx: new folder $T/w/gone does not exist" <<< "$(R --seat cx 2>&1)" && ok "a folder that is not there is refused" || bad "gone: $(R --seat cx 2>&1)"
printf 'cx %s\n' "$T/w/cl" > "$T/moves"
grep -q "^UNRESOLVED cx: new folder $T/w/cl is already a seat's folder" <<< "$(R --seat cx 2>&1)" && ok "another seat's folder is refused" || bad "taken: $(R --seat cx 2>&1)"
printf 'cx %s\ncxi %s\n' "$T/w/new" "$T/w/new" > "$T/moves"
grep -q "^UNRESOLVED cx: two seats would move to" <<< "$(R --seat cx 2>&1)" && ok "two seats in one folder are refused" || bad "two: $(R --seat cx 2>&1)"
printf 'cx %s\ncx %s\n' "$T/w/new" "$T/w/newgit" > "$T/moves"
grep -q "^UNRESOLVED cx: more than one line" <<< "$(R --seat cx 2>&1)" && ok "two lines for one seat are refused" || bad "two lines: $(R --seat cx 2>&1)"
printf 'cx %s\n' "$T/w/new" > "$T/moves"
grep -q '^UNRESOLVED cx: it moves folder, so .* must name its thread' <<< "$(ZEO_RESCUE_PINS=$T/no-pins R --seat cx 2>&1)" && ok "a seat with no pinned thread cannot move" || bad "no pin"
printf 'cx %s\n' "$T/w/newgit" > "$T/moves"; : > "$T/config.toml"
grep -q 'stop at a question nobody may answer' <<< "$(R --seat cx 2>&1)" && ok "a git folder with no trust entry is refused before anything stops" || bad "trust: $(R --seat cx 2>&1)"
printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$T/w/newgit" > "$T/config.toml"
grep -q 'stop at a question' <<< "$(R --seat cx 2>&1)" && ok "and so is an untrusted entry" || bad "untrusted"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$T/w/newgit" > "$T/config.toml"
grep -q '^RESUME cx:' <<< "$(R --seat cx 2>&1)" && ok "a trusted git folder passes" || bad "trusted: $(R --seat cx 2>&1)"
printf 'cx %s\n' "$T/w/new" > "$T/moves"; fresh
out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "^MOVED OK cx: thread $SID, one rollout, one writer, in $T/w/new" && ok "a move proves one thread, one rollout, one writer" || bad "move: $rc $out"
echo "$out" | grep -q "^MOVE cx: from $T/w/cx to $T/w/new" && ok "the plan says where from and to" || bad "move line: $out"
grep -q -- "resume -a never -s danger-full-access -C $T/w/new --no-daemon $SID" "$T/launched" && ok "it resumes the pinned thread in the new folder" || bad "argv: $(cat "$T/launched")"
grep -q "moved from $T/w/cx to $T/w/new" "$T/state/prompts/cx.txt" && ok "the seat is told" || bad "note"
rm -f "$T/sqlargs"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
dirs=$(sed -n 's#/db$##p' "$T/sqlargs" | sort -u); left=""; for d in $dirs; do [ ! -e "$d" ] || left="$left $d"; done
[ $rc -eq 0 ] && echo "$out" | grep -q '^MOVED OK cx' && [ -n "$dirs" ] && ! grep -q -v '/zeo-codex-db\.[A-Za-z0-9]*/db$' "$T/sqlargs" && [ -z "$left" ] && ok "Codex's database is read only on a private copy, never in place or immutable, and each copy is deleted" || bad "db copy: $rc $out $(cat "$T/sqlargs") left:$left"
# db_read, on a real database whose row is only in its -wal
WD=$T/walt; mkdir -p "$WD/tmp"; /usr/bin/sqlite3 "$WD/s.db" "pragma journal_mode=wal; create table threads (id text, cwd text);" >/dev/null
printf '.dbconfig no_ckpt_on_close on\npragma wal_autocheckpoint=0;\ninsert into threads values (%s);\n' "'w1', '/x'" | /usr/bin/sqlite3 "$WD/s.db" >/dev/null
fnsrc() { awk -v f="$1() {" 'index($0, f) == 1 {p = 1} p {print} p && /^}/ {p = 0} index($0, "db_stamp() {") == 1 {print}' "$2"; }
dbr() { ( eval "$(fnsrc "$1" "$2")"; SQLITE=/usr/bin/sqlite3 CODEX_DB=$WD/s.db TMPDIR=$WD/tmp; [ -z "${3:-}" ] || eval "$3"; "$1" 'select id from threads;' ) 2>&1; }
[ -s "$WD/s.db-wal" ] && [ "$(/usr/bin/sqlite3 "file:$WD/s.db?mode=ro&immutable=1" 'select count(*) from threads;')" = 0 ] && ok "the test row is only in the -wal: an immutable read misses it" || bad "wal fixture"
for fs in "db_read $HERE/rescue.sh"; do set -- $fs
  [ "$(dbr "$1" "$2")" = w1 ] && [ -z "$(ls "$WD/tmp")" ] && [ -s "$WD/s.db-wal" ] && ok "$1 in $(basename "$2") reads it, leaves no copy, and leaves the -wal as it was" || bad "$1 wal: $(dbr "$1" "$2")"
  [ "$(dbr "$1" "$2" 'cp() { command cp "$@"; [ -e "$WD/once" ] || { : > "$WD/once"; touch "$CODEX_DB-wal"; }; }')" = w1 ] && ok "$1: a -wal written during the copy is copied again" || bad "$1 retry"
  rm -f "$WD/once"; out=$(dbr "$1" "$2" 'cp() { command cp "$@"; touch "$CODEX_DB-wal"; }'); rc=$?
  [ $rc -ne 0 ] && [ -z "$out" ] && [ -z "$(ls "$WD/tmp")" ] && ok "$1: one that never stops changing reads nothing, and leaves no copy" || bad "$1 busy: $rc $out"
done
{ printf '{"cwd":"%s"}\n' "$T/w/new"; head -c 1000000 /dev/zero | tr '\0' x; echo; } > "$T/rolladd"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q '^MOVED OK cx' && ok "a rollout larger than the pipe does not stop a good seat" || bad "big rollout: $rc $out"
printf '{"cwd":"%s"}\n' "$T/w/new" > "$T/rolladd"
touch "$T/latehold"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?; rm -f "$T/latehold" "$T/heldlate"
[ $rc -eq 0 ] && echo "$out" | grep -q '^MOVED OK cx' && ok "a rollout that opens a moment late does not stop a good seat" || bad "late hold: $rc $out"
echo "$T/w/cx" > "$T/threadcwd"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q '^NOTE cx: Codex.s thread record still says' && ok "an old thread record is named, and does not stop a seat the pin still finds" || bad "record: $rc $out"
echo "$T/w/new" > "$T/threadcwd"
: > "$T/sessions/rollout-copy-$SID.jsonl"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "^STOPPED: cx: 2 rollouts carry thread $SID" && ok "a second rollout stops the run" || bad "rollouts: $rc $out"
rm -f "$T/sessions/rollout-copy-$SID.jsonl"
echo 1 > "$T/newthreads"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q '^STOPPED: cx: 1 new threads appeared' && ok "a new thread in the folder stops the run" || bad "new thread: $rc $out"
echo 0 > "$T/newthreads"; printf '9\n77\n' > "$T/heldafter"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "^STOPPED: cx: its rollout is held by pids '9 77'" && ok "a second writer stops the run" || bad "writer: $rc $out"
echo 9 > "$T/heldafter"; rm -f "$T/rolladd"; fresh; out=$(R --apply --seat cx 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "^STOPPED: cx: its thread never recorded $T/w/new" && ok "a thread that never reached the folder stops the run" || bad "never: $rc $out"
echo "$out" | grep -q '^RECOVERY: 1 seats' && ok "and says what is down" || bad "move recovery"
printf '{"cwd":"%s"}\n' "$T/w/new" > "$T/rolladd"
echo "-- --relaunch restarts only the seats that need it"
fresh; echo cx-maintainer >> "$T/live"; echo 'cx-maintainer|%8|800|1|codex' > "$T/panes"
echo "800 /x/codex resume -a never -s danger-full-access -C $T/w/cx --no-daemon $SID p" > "$T/ps.out"; printf 'HOME=/x' > "$T/psE.out"
: > "$T/moves"
grep -q '^OK cx: started by rescue' <<< "$(R --reseat --seat cx 2>&1)" && ok "without --relaunch a seat rescue started is left alone" || bad "plain reseat"
grep -q '^RESEAT cx:' <<< "$(R --reseat --relaunch --seat cx 2>&1)" && ok "with it, a process without settings is restarted" || bad "relaunch: $(R --reseat --relaunch --seat cx 2>&1)"
printf '%s' "$GOOD" > "$T/psE.out"
grep -q '^OK cx: started by rescue, right already' <<< "$(R --reseat --relaunch --seat cx 2>&1)" && ok "a seat with everything right is left alone, so the line can run again" || bad "right: $(R --reseat --relaunch --seat cx 2>&1)"
echo "a note" > "$T/rnote"; out=$(R --reseat --relaunch --restart --seat cx --note-file "$T/rnote" 2>&1)
echo "$out" | grep -q '^RESEAT cx:' && ! echo "$out" | grep -q 'right already' && ok "--restart restarts a seat that reads as right, so its note reaches it" || bad "restart: $out"
out=$(R --reseat --relaunch --restart --seat cx 2>&1); [ $? -eq 2 ] && ! echo "$out" | grep -q '^RESEAT' && ok "but only with a note" || bad "restart no note: $out"
out=$(R --reseat --restart --seat cx --note-file "$T/rnote" 2>&1); [ $? -eq 2 ] && ! echo "$out" | grep -q '^RESEAT' && ok "and only with --relaunch" || bad "restart no relaunch: $out"
out=$(R --reseat --relaunch --restart --seat cx --seat cl --note-file "$T/rnote" 2>&1); [ $? -eq 2 ] && echo "$out" | grep -q 'needs exactly one --seat' && ok "and for exactly one seat" || bad "restart two: $out"
out=$(R --reseat --relaunch --restart --note-file "$T/rnote" 2>&1); [ $? -eq 2 ] && echo "$out" | grep -q 'needs exactly one --seat' && ok "never for every seat" || bad "restart all: $out"
echo "-- --upgrade restarts a seat whose process runs an older binary than the one installed"
mkdir -p "$T/inst/new" "$T/inst/old"; printf '#!/bin/sh\n' > "$T/inst/new/codex"; printf '#!/bin/sh\n' > "$T/inst/new/claude"; chmod +x "$T/inst/new/codex" "$T/inst/new/claude"
ln -sfn "$T/inst/new/codex" "$T/codexlink"; ln -sfn "$T/inst/new/claude" "$T/claudelink"
NEWCX=$(/usr/bin/perl -MCwd=abs_path -e 'print abs_path(shift)' "$T/inst/new/codex"); NEWCL=$(/usr/bin/perl -MCwd=abs_path -e 'print abs_path(shift)' "$T/inst/new/claude")
U() { ZEO_RESCUE_CODEX=$T/codexlink ZEO_RESCUE_CLAUDE=$T/claudelink R "$@"; }
printf 'p800\nfcwd\nn%s/w/cx\n' "$T" > "$T/lsof.out"
printf 'p800\nftxt\nn%s/inst/old/codex\nftxt\nn/usr/lib/dyld\n' "$T" > "$T/lsof.txt"
out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -qxF "UPGRADE cx: pid 800 runs $T/inst/old/codex; installed now is $NEWCX" && echo "$out" | grep -q '^RESEAT cx:' && ok "a seat on an older binary is restarted, and the plan says which binary it runs" || bad "upgrade stale: $out"
grep -q '^OK cx: started by rescue, right already' <<< "$(U --reseat --relaunch --seat cx 2>&1)" && ok "without --upgrade the binary is not looked at, so earlier lines keep their meaning" || bad "no upgrade: $(U --reseat --relaunch --seat cx 2>&1)"
printf 'p800\nftxt\nn%s\nftxt\nn/usr/lib/dyld\n' "$NEWCX" > "$T/lsof.txt"
out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -q '^OK cx: started by rescue, right already' && ! echo "$out" | grep -q '^UPGRADE' && ok "a seat already on the installed binary is left alone, so the line can run again" || bad "upgrade current: $out"
: > "$T/lsof.txt"; out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -q '^UNRESOLVED cx: could not read which binary pid 800 runs' && ! echo "$out" | grep -q '^RESEAT' && ok "a binary that cannot be read is UNRESOLVED, never a guess" || bad "upgrade unread: $out"
printf 'p800\nftxt\nn/usr/lib/dyld\n' > "$T/lsof.txt"; out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -q '^UNRESOLVED cx: could not read which binary' && ok "and so is a process that maps no harness binary" || bad "upgrade no harness: $out"
out=$(U --reseat --upgrade --seat cx 2>&1); [ $? -eq 2 ] && ! echo "$out" | grep -q '^RESEAT' && ok "--upgrade needs --relaunch" || bad "upgrade no relaunch: $out"
out=$(ZEO_RESCUE_CODEX=$T/nowhere ZEO_RESCUE_CLAUDE=$T/claudelink R --reseat --relaunch --upgrade --seat cx 2>&1); [ $? -eq 1 ] && echo "$out" | grep -q 'resolves to no executable file' && ok "a harness CLI that resolves to nothing stops the run before any seat" || bad "upgrade no cli: $out"
out=$(ZEO_RESCUE_CODEX=$T/nowhere ZEO_RESCUE_CLAUDE=$T/claudelink R --reseat --relaunch --upgrade --harness claude --seat cl 2>&1); echo "$out" | grep -q 'resolves to no executable file' && bad "claude-only run read the codex cli: $out" || ok "a run of one harness reads only that harness's CLI"
out=$(ZEO_RESCUE_LSOF=$T/no-lsof U --reseat --relaunch --upgrade --seat cx 2>&1); [ $? -eq 1 ] && echo "$out" | grep -q 'needs lsof' && ok "--upgrade with no lsof stops the run" || bad "upgrade no lsof: $out"
printf 'p800\nftxt\nn%s/inst/old/codex\n' "$T" > "$T/lsof.txt"
out=$(U --reseat --relaunch --upgrade --except cx 2>&1)
echo "$out" | grep -qxF 'EXCEPT cx: left out of this run' && ! echo "$out" | grep -q 'RESEAT cx\|UPGRADE cx' && ok "--except leaves a seat out of the run" || bad "except: $out"
out=$(U --check --except cx 2>&1); echo "$out" | grep -qE "^(OK|WRONG) cx " && bad "check judged an excepted seat: $out" || ok "and out of a check"
printf 'cx %s carry\n' "$T/w/new" > "$T/moves"; printf 'p800\nftxt\nn%s/inst/old/codex\n' "$T" > "$T/lsof.txt"
out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -q '^RESEAT cx:' && ! echo "$out" | grep -q '^MOVE\|carry' && ok "an upgrade never moves or carries a seat, whatever folder-moves says" || bad "upgrade move: $out"
# --in-place: a restart never acts on a folder-moves line (the 14 Nov account move: a pending carry-plain stopped a --restart)
echo 'You were restarted for a test.' > "$T/inote"; printf 'p800\nfcwd\nn%s/w/cx\n' "$T" > "$T/lsof.out"; printf 'cx %s carry-plain\n' "$T/w/new" > "$T/moves"
out=$(R --reseat --relaunch --restart --note-file "$T/inote" --seat cx 2>&1)
echo "$out" | grep -qE '^(MOVE cx|UNRESOLVED cx: .*(carr|plain|git|trust))' && ok "positive control: without --in-place, a restart acts on the seat's pending carry line" || bad "inplace control: $out"
out=$(R --reseat --relaunch --restart --in-place --note-file "$T/inote" --seat cx 2>&1)
echo "$out" | grep -q '^RESEAT cx:' && ! echo "$out" | grep -qiE '^MOVE|carry' && ok "--in-place restarts it where its process works, and acts on no folder-moves line" || bad "inplace: $out"
out=$(R --relaunch --in-place --seat cx 2>&1); [ $? -eq 2 ] && ok "--in-place goes only with --reseat" || bad "inplace usage: $out"
grep -v '^cx-maintainer$' "$T/live" > "$T/live.x"; cp "$T/live" "$T/live.keep"; mv "$T/live.x" "$T/live"
out=$(R --reseat --relaunch --in-place --seat cx 2>&1); mv "$T/live.keep" "$T/live"
echo "$out" | grep -q '^DOWN cx: an in-place restart restarts only live seats' && ! echo "$out" | grep -q '^RESUME' && ok "a seat that is down is DOWN under --in-place, never resumed elsewhere" || bad "inplace down: $out"
printf 'p800\nfcwd\nn%s/w/elsewhere\n' "$T" > "$T/lsof.out"; out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -q "^UNRESOLVED cx: pid 800 works in $T/w/elsewhere, which is not its chart folder $T/w/cx nor the folder of its line, $T/w/new" && ! echo "$out" | grep -q '^RESEAT' && ok "a seat working outside its chart folder and its line's is not restarted" || bad "upgrade elsewhere: $out"
: > "$T/lsof.out"; out=$(U --reseat --relaunch --upgrade --seat cx 2>&1)
echo "$out" | grep -q "^UNRESOLVED cx: pid 800 works in a folder lsof cannot read" && ok "nor one whose folder cannot be read" || bad "upgrade cwd unread: $out"
: > "$T/moves"; printf 'p800\nfcwd\nn%s/w/cx\n' "$T" > "$T/lsof.out"
grep -v '^cx-maintainer$' "$T/live" > "$T/live.x"; cp "$T/live" "$T/live.keep"; mv "$T/live.x" "$T/live"
out=$(U --reseat --relaunch --upgrade --seat cx 2>&1); rc=$?
echo "$out" | grep -q '^DOWN cx: an upgrade restarts only live seats' && ! echo "$out" | grep -q '^RESUME' && [ $rc -eq 3 ] && ok "a seat that is down is named DOWN, not resumed, and the run exits 3" || bad "upgrade down: $rc $out"
mv "$T/live.keep" "$T/live"
printf 'cx %s\n' "$T/w/new" > "$T/moves"
out=$(R --reseat --relaunch --seat cx 2>&1)
echo "$out" | grep -q '^RESEAT cx:' && echo "$out" | grep -q '^MOVE cx' && ok "a right seat in the old folder is restarted to move" || bad "to move: $out"
grep -q "^WRONG cx (codex): not yet in its new folder $T/w/new" <<< "$(R --check --seat cx 2>&1)" && ok "--check names a seat not yet moved" || bad "check move: $(R --check --seat cx 2>&1)"
echo "800 /x/codex resume -a never -s danger-full-access -C $T/w/new --no-daemon $SID p" > "$T/ps.out"
grep -q '^OK cx: started by rescue, right already' <<< "$(R --reseat --relaunch --seat cx 2>&1)" && ok "a moved seat is left alone" || bad "moved: $(R --reseat --relaunch --seat cx 2>&1)"
grep -q '^OK cx (codex)' <<< "$(R --check --seat cx 2>&1)" && ok "and passes --check" || bad "check moved: $(R --check --seat cx 2>&1)"
printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct GIT_ALLOW_PROTOCOL=file' > "$T/psE.out"
grep -q '^UNRESOLVED cx: a shell outside its folder has git off; a restart would not change that' <<< "$(R --reseat --relaunch --seat cx 2>&1)" && ok "a fault a restart cannot fix stops short of a restart" || bad "unfixable: $(R --reseat --relaunch --seat cx 2>&1)"
echo "900 /x/codex resume -a never -s danger-full-access -C /x --no-daemon 99999999-9999-4999-8999-999999999999 p" > "$T/ps.out"
sed -i '' 's/^cx-maintainer|%8|800|1|codex$/cx-maintainer|%8|900|1|codex/' "$T/panes"
grep -q "^UNRESOLVED cx: its pane does not hold $SID" <<< "$(R --reseat --relaunch --seat cx 2>&1)" && ok "a pane holding another thread is not touched" || bad "other thread: $(R --reseat --relaunch --seat cx 2>&1)"
"$HERE/rescue.sh" --relaunch >/dev/null 2>&1; [ $? -eq 2 ] && ok "--relaunch needs --reseat" || bad "relaunch alone"
printf '' > "$T/psE.out"; : > "$T/moves"; : > "$T/ps.out"; : > "$T/panes"; rm -f "$T/heldafter" "$T/rolladd" "$T/snapwrite"; export ZEO_RESCUE_PINS="$T/no-pins"; reset_live

echo "-- a Claude seat moves folder and keeps its session, memory and transcript"
CS=22222222-2222-4222-8222-222222222222; enc2() { printf %s "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'; }
CO=$T/projects/$(enc2 "$T/w/cl"); CN=$T/projects/$(enc2 "$T/w/cnew"); mkdir -p "$T/w/cnew" "$CO/memory"; echo m > "$CO/memory/MEMORY.md"
cp -R "$CO" "$T/cproj"
printf 'cl %s\n' "$CS" > "$T/cpins"; export ZEO_RESCUE_PINS="$T/cpins" ZEO_RESCUE_MOVES="$T/moves" ZEO_RESCUE_CLAUDE_JSON="$T/claude.json"
printf 'cl %s\n' "$T/w/cnew" > "$T/moves"; echo master > "$T/seatmark"
printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=cl GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x' > "$T/psE.out"; : > "$T/ps.out"; : > "$T/lsof.out"
cfresh() { reset_live; rm -rf "$CO" "$CN"; cp -R "$T/cproj" "$CO"; printf '{"cwd":"%s"}\n' "$T/w/cnew" > "$T/claudeadd"; : > "$T/ps.out"; }
trustnew() { printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$T/w/cnew" > "$T/claude.json"; }
echo '{"projects":{}}' > "$T/claude.json"; cfresh
grep -q 'has no trusted entry in .* so Claude would stop at a question nobody may answer' <<< "$(R --seat cl 2>&1)" && ok "a folder with no trust entry is refused, git or not" || bad "claude trust: $(R --seat cl 2>&1)"
trustnew
git -C "$T/w/newgit" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x; git -C "$T/w/newgit" worktree add -q "$T/w/cwt" 2>/dev/null
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$T/w/cwt" > "$T/claude.json"; printf 'cl %s\n' "$T/w/cwt" > "$T/moves"
grep -q 'is a git worktree, and no Claude move into one is proved' <<< "$(R --seat cl 2>&1)" && ok "a worktree target is refused" || bad "worktree: $(R --seat cl 2>&1)"
trustnew; printf 'cl %s\n' "$T/w/cnew" > "$T/moves"; mkdir -p "$CN"
grep -q 'it has projects under both folders' <<< "$(R --seat cl 2>&1)" && ok "two projects are never merged" || bad "both: $(R --seat cl 2>&1)"
cfresh; out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "^MOVED OK cl: session $CS, one transcript, one process, in $T/w/cnew" && ok "a move proves one transcript, one process" || bad "claude move: $rc $out"
[ -f "$CN/memory/MEMORY.md" ] && [ -f "$CN/$CS.jsonl" ] && [ ! -e "$CO" ] && ok "the whole project goes by one rename, memory too" || bad "project: $(ls "$T/projects")"
grep -q -- "-c $T/w/cnew -- $HERE/seat-exec.sh cl claude" "$T/launched" && ok "it starts in the new folder" || bad "launch: $(cat "$T/launched")"
cp "$CN/$CS.jsonl" "$T/keep.jsonl"
cfresh; cp "$T/keep.jsonl" "$CO/$CS.jsonl"; rm -f "$T/claudeadd"; out=$(R --apply --seat cl 2>&1); rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "^STOPPED: cl: its transcript took no line from" && ok "an old record of the folder does not pass: only new bytes count" || bad "vacuous: $rc $out"
cfresh; mkdir -p "$T/projects/x"; : > "$T/projects/x/$CS.jsonl"; out=$(R --apply --seat cl 2>&1); rc=$?; rm -rf "$T/projects/x"
[ $rc -eq 1 ] && echo "$out" | grep -q 'STOPPED: cl: 2 transcripts carry session' && ok "a second transcript stops the run" || bad "two transcripts: $rc $out"
cfresh; touch "$T/forksession"; out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/forksession"
[ $rc -eq 1 ] && echo "$out" | grep -q 'STOPPED: cl: 1 new sessions appeared' && ok "a forked session stops the run" || bad "fork: $rc $out"
cfresh; touch "$T/secondclaude"; out=$(R --apply --seat cl 2>&1); rc=$?; rm -f "$T/secondclaude"
[ $rc -eq 1 ] && echo "$out" | grep -q "^STOPPED: cl: session $CS is held by pids '9 77'" && ok "a second process stops the run" || bad "second process: $rc $out"
cfresh; echo "800 /x/claude --resume $CS" > "$T/ps.out"; echo cl-maintainer >> "$T/live"; echo 'cl-maintainer|%3|800|1|claude' > "$T/panes"
out=$(R --reseat --relaunch --seat cl 2>&1); echo "$out" | grep -q '^RESEAT cl:' && echo "$out" | grep -q '^MOVE cl' && ok "a right seat still under its old folder is restarted to move" || bad "relaunch claude: $out"
grep -q 'not yet in its new folder' <<< "$(R --check --seat cl 2>&1)" && ok "--check names it" || bad "check claude: $(R --check --seat cl 2>&1)"
mv "$CO" "$CN"
grep -q '^OK cl: started by rescue, right already' <<< "$(R --reseat --relaunch --seat cl 2>&1)" && ok "once its project has moved it is left alone" || bad "claude right: $(R --reseat --relaunch --seat cl 2>&1)"
grep -q '^OK cl (claude)' <<< "$(R --check --seat cl 2>&1)" && ok "and passes --check" || bad "check moved: $(R --check --seat cl 2>&1)"
: > "$T/moves"; mv "$CN" "$CO"; mv "$T/w/cl" "$T/w/cl.gone"; rm -f "$T/launched"; out=$(R --reseat --relaunch --apply --seat cl 2>&1); rc=$?; mv "$T/w/cl.gone" "$T/w/cl"
[ $rc -eq 3 ] && echo "$out" | grep -q "^UNRESOLVED cl: no directory $T/w/cl" && [ ! -e "$T/launched" ] && ok "a live seat whose folder is gone, with no line, is named and left alone" || bad "gone folder: $rc $out"
rm -rf "$CO"; mkdir -p "$CN"
: > "$T/moves"; : > "$T/ps.out"; : > "$T/panes"; printf '' > "$T/psE.out"; rm -f "$T/claudeadd"; rm -rf "$CN"; cp -R "$T/cproj" "$CO"; export ZEO_RESCUE_PINS="$T/no-pins"; reset_live

echo "-- a seat's own clone is carried to <repo>/main while it is stopped (a carry line in folder-moves)"
# git reports real paths, so this part works under the real path of the temp folder
K=$(cd "$T" && pwd -P)/k KS=88888888-8888-4888-8888-888888888888 KX=44444444-4444-4444-8444-444444444444
KF=$K/org/ka KT=$K/org/ka/main KW=$K/ext/ka-wt KB=$K/org/kb
kgit() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }
mkdir -p "$K/org" "$K/ext" "$K/other"; kgit init -q "$KF"; echo a > "$KF/a"; kgit -C "$KF" add a; kgit -C "$KF" commit -qm a
kgit -C "$KF" worktree add -q "$KW" -b side 2>/dev/null; kgit -C "$KF" worktree add -q "$K/ext/gone" -b gone 2>/dev/null; rm -rf "$K/ext/gone"; echo u > "$KF/untracked"
kgit init -q "$KB"; kgit -C "$KB" commit -q --allow-empty -m b
cp -Rp "$K" "$T/k.orig"; KHEAD=$(git -C "$KF" rev-parse HEAD)
KP=$T/projects/$(enc "$KF") KPN=$T/projects/$(enc "$KT")
printf '{"seats":[%s,%s,%s]}' "$(row ka ka claude h ka-s "$KF")" "$(row kx kx codex h kx-s "$KB")" "$(row kd kd claude h kd-s "$KB")" > "$T/kchart.json"
printf 'ka %s\nkx %s\nkd %s\n' "$KS" "$KX" "$KS" > "$T/kpins"
KR() { ZEO_RESCUE_PINS="$T/kpins" ZEO_RESCUE_MOVES="$T/kmoves" ZEO_RESCUE_CLAUDE_JSON="$T/kj.json" ZEO_RESCUE_CODEX_CONFIG="$T/kc.toml" "$HERE/rescue.sh" --host h --stagger 0 --chart "$T/kchart.json" "$@" 2>&1; }
kmove() { printf 'ka %s %s\n' "$1" "${2:-carry}" > "$T/kmoves"; }
ktrust() { printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}' "$1" > "$T/kj.json"; }
kreset() { # the seat is up in its clone, idle, a child of it in a subfolder; on the stop its process goes, as a real stop does
  reset_live; rm -rf "$K" "$KP" "$KPN"; cp -Rp "$T/k.orig" "$K"; mkdir -p "$KP/memory"; echo m > "$KP/memory/MEMORY.md"; echo '{"permissionMode":"auto"}' > "$KP/$KS.jsonl"
  echo ka-s >> "$T/live"; echo 'ka-s|%5|9|1|claude' > "$T/panes"; echo "9 /x/claude --resume $KS" > "$T/ps.out"; printf '9 1\n501 9\n' > "$T/pstree"
  printf 'p9\nn%s\np501\nn%s/sub\np600\nn%s\n' "$KF" "$KF" "$K/org" > "$T/lsof.out"; kmove "$KT"; ktrust "$KT"; : > "$T/kc.toml"
  printf ': > "%s"; : > "%s"; rm -f "%s"\n' "$T/ps.out" "$T/lsof.out" "$T/onstop" > "$T/onstop"
  printf '{"cwd":"%s"}\n' "$KT" > "$T/claudeadd"; printf 'ZEO_TMUX_SEAT=master ZEO_TMUX_ACCOUNT=acct ZMAIL_INSTANCE=ka GIT_ALLOW_PROTOCOL=ssh:https:file HOME=/x' > "$T/psE.out"
}
KP1() { KR --reseat --relaunch --seat ka; }
kreset
out=$(KP1); grep -q "^RESEAT ka: claude $KS " <<< "$out" && grep -qxF "MOVE ka: from $KF to $KT, carrying the clone while the seat is stopped" <<< "$out" && ok "a ready carry is planned, and says so" || bad "carry plan: $out"
[ ! -e "$T/launched" ] || [ ! -s "$T/launched" ] && [ ! -e "$KT" ] && ok "the plan moves nothing" || bad "plan moved"
grep -qxF "WRONG ka (claude): not yet carried to $KT; the carry is ready" <<< "$(KR --check --seat ka)" && ok "--check names a carry still to run" || bad "carry check: $(KR --check --seat ka)"
echo '{"projects":{}}' > "$T/kj.json"; grep -q "^UNRESOLVED ka: $KT has no trusted entry in" <<< "$(KP1)" && ok "a carry with no trust entry for the new folder is refused" || bad "carry trust: $(KP1)"
kreset; kmove "$KT" kerry; grep -q "^UNRESOLVED ka: its line in .* ends in 'kerry', and only carry and carry-plain are known" <<< "$(KP1)" && ok "an unknown third word is refused" || bad "kerry: $(KP1)"
kreset; mv "$KF/.git" "$KF/.git.x"; grep -q "^UNRESOLVED ka: $KF is not the top of a git clone" <<< "$(KP1)" && ok "a folder that is not a clone is not carried" || bad "not git: $(KP1)"; mv "$KF/.git.x" "$KF/.git"
kreset; printf 'ka %s\n' "$KS" > "$T/kpins2"; printf 'ka %s carry\n' "$KW/main" > "$T/kmoves"; printf '{"seats":[%s]}' "$(row ka ka claude h ka-s "$KW")" > "$T/kchart2.json"; ktrust "$KW/main"
grep -q "^UNRESOLVED ka: $KW is not an ordinary clone with its own .git" <<< "$(KR --reseat --relaunch --seat ka --chart "$T/kchart2.json")" && ok "a linked worktree is not carried" || bad "worktree carry: $(KR --reseat --relaunch --seat ka --chart "$T/kchart2.json")"
kreset; kmove "$KF/x/main"; ktrust "$KF/x/main"; grep -q "^UNRESOLVED ka: $KF/x/main is more than one level inside $KF" <<< "$(KP1)" && ok "only one level down" || bad "deep: $(KP1)"
kreset; kmove "$KB/sub/main"; ktrust "$KB/sub/main"; grep -q "^UNRESOLVED ka: $KB is in git, so $KB/sub/main would be inside a repository" <<< "$(KP1)" && ok "never into another repository" || bad "into repo: $(KP1)"
kreset; kmove "$K/none/a/main"; ktrust "$K/none/a/main"; grep -q "^UNRESOLVED ka: neither $K/none/a nor its parent is a folder" <<< "$(KP1)" && ok "at most one new folder is made" || bad "two levels: $(KP1)"
kreset; kmove /dev/zeo-rescue-test/main; ktrust /dev/zeo-rescue-test/main; grep -q "^UNRESOLVED ka: /dev/zeo-rescue-test/main is on another volume, so the move would be a copy" <<< "$(KP1)" && ok "never across volumes" || bad "volume: $(KP1)"
kreset; kgit -C "$KF" worktree add -q "$KF/inner" -b inner 2>/dev/null; grep -q "^UNRESOLVED ka: its linked worktree $KF/inner is inside it" <<< "$(KP1)" && ok "a worktree inside the clone is refused" || bad "inner: $(KP1)"
kreset; git -C "$KF" config zeo.path "$KF/x"; grep -q "^UNRESOLVED ka: its git config names its own path" <<< "$(KP1)" && ok "a git config that names its own path is refused" || bad "config: $(KP1)"
kreset; mkdir -p "$KPN"; grep -q "^UNRESOLVED ka: $KPN already exists, and two projects are not merged here" <<< "$(KP1)" && ok "a project under the new key is refused" || bad "new key: $(KP1)"
kreset; mkdir "$KT"; grep -q "^UNRESOLVED ka: $KT is there, but it is not a carried clone with its own .git" <<< "$(KP1)" && ok "a new path that is there but is not the clone is refused" || bad "there: $(KP1)"
kreset; printf 'p700\nn%s/sub\n' "$KF" >> "$T/lsof.out"; grep -q "^UNRESOLVED ka: pid 700 works in $KF and is not the seat's own" <<< "$(KP1)" && ok "another process working in the clone stops the plan" || bad "holder: $(KP1)"
kreset; printf '2\n' > "$T/lsof.fail-cwd"; grep -q "^UNRESOLVED ka: which processes work in $KF cannot be read (lsof exited 2), so it is not carried" <<< "$(KP1)" && ok "an lsof that cannot list working folders stops the plan, as a holder would" || bad "cwd fail plan: $(KP1)"; rm -f "$T/lsof.fail-cwd"
kreset; rm -f "$T/launched"; printf 'printf "1\\nlsof: WARNING: can not stat a mount\\n" > "%s"\n' "$T/lsof.fail-cwd" >> "$T/onstop"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 1 ] && grep -q "^FAILED ka: which processes work in $KF cannot be read (lsof exited 1: lsof: WARNING: can not stat a mount *); nothing was moved; it was not started" <<< "$out" && [ -d "$KF/.git" ] && [ ! -e "$KT" ] && ! grep -q 'seat-exec.sh' "$T/launched" \
  && ok "and if it fails after the stop, the clone is not carried and the seat is not started" || bad "cwd fail apply: $rc $out"
rm -f "$T/lsof.fail-cwd"
kreset; : > "$T/live"; grep -q "^UNRESOLVED ka: it is down, and a carry moves only a seat this run stops itself" <<< "$(KR --seat ka)" && ok "a seat that is down is not carried" || bad "down: $(KR --seat ka)"
kreset; printf 'kx %s carry\n' "$KB/main" > "$T/kmoves"; echo kx-s >> "$T/live"; echo 'kx-s|%6|9|1|codex' > "$T/panes"; echo "9 /x/codex resume -a never -s danger-full-access -C $KB --no-daemon $KX" > "$T/ps.out"
grep -q "^UNRESOLVED kx: $KB/main has no trusted entry in $T/kc.toml" <<< "$(KR --reseat --relaunch --seat kx)" && ok "a Codex carry needs its trust entry too, though the folder is not there yet" || bad "codex trust: $(KR --reseat --relaunch --seat kx)"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$KB/main" > "$T/kc.toml"
out=$(KR --reseat --relaunch --seat kx); grep -q "^RESEAT kx: codex $KX" <<< "$out" && grep -qxF "MOVE kx: from $KB to $KB/main, carrying the clone while the seat is stopped" <<< "$out" && ok "and with it, the Codex carry is planned" || bad "codex carry: $out"
kreset; rm -f "$T/launched"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 0 ] && grep -qxF "CARRIED ka: $KF to $KT, the same folder (inode $(stat -f %i "$T/k.orig/org/ka" >/dev/null; sed -n 's/.*(inode \([0-9]*\)).*/\1/p' <<< "$out" | head -1)) at $KHEAD; 1 linked worktrees elsewhere repaired" <<< "$out" && grep -q "^MOVED OK ka: session $KS, one transcript, one process, in $KT" <<< "$out" && ok "the carry runs: the clone moves, its worktree is repaired, the move is proved" || bad "carry apply: $rc $out"
ki=$(sed -n 's/.*(inode \([0-9]*\)).*/\1/p' <<< "$out" | head -1)
[ -n "$ki" ] && [ "$(stat -f %i "$KT")" = "$ki" ] && [ "$(git -C "$KT" rev-parse HEAD)" = "$KHEAD" ] && [ -f "$KT/untracked" ] && [ "$(ls -A "$KF")" = main ] && [ "$(stat -f %Lp "$KF")" = 755 ] && ok "the same folder, HEAD and untracked file are at main, and the old path holds only main" || bad "carried: $(ls -A "$KF") $(stat -f %i "$KT") $ki"
[ "$(git -C "$KW" rev-parse --path-format=absolute --git-common-dir)" = "$KT/.git" ] && git -C "$KW" status --porcelain >/dev/null && [ "$(git -C "$KT" worktree list --porcelain | grep -c '^prunable')" = 1 ] && ok "the linked worktree reaches the clone at its new place; the prunable one is left as it was" || bad "repair: $(git -C "$KW" rev-parse --git-common-dir 2>&1)"
[ -f "$KPN/$KS.jsonl" ] && [ -f "$KPN/memory/MEMORY.md" ] && [ ! -e "$KP" ] && ok "its project went with it, memory too" || bad "carry project: $(ls "$T/projects")"
grep -qF -- "-c $K/org -- sleep 3600" "$T/launched" && grep -qF -- "-c $KT -- $HERE/seat-exec.sh ka claude" "$T/launched" && ok "it is stopped outside the clone and started in main" || bad "carry launch: $(cat "$T/launched")"
grep -q "^OK ka (claude)" <<< "$(KR --check --seat ka)" && ok "after the carry it checks right" || bad "carry check after: $(KR --check --seat ka)"
grep -q '^OK ka: started by rescue, right already' <<< "$(KR --reseat --relaunch --seat ka)" && ok "a second run leaves it alone" || bad "carry twice: $(KR --reseat --relaunch --seat ka)"
kreset; printf ': > "%s"; printf "p800\\nn%s\\n" > "%s"; rm -f "%s"\n' "$T/ps.out" "$KF" "$T/lsof.out" "$T/onstop" > "$T/onstop"; ki0=$(stat -f %i "$KF"); rm -f "$T/launched"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 1 ] && grep -q "^FAILED ka: pid 800 still works in $KF after the stop; nothing was moved; it was not started" <<< "$out" && [ "$(stat -f %i "$KF")" = "$ki0" ] && [ ! -e "$KT" ] && [ -f "$KP/$KS.jsonl" ] && ok "a process still in the clone after the stop: nothing moves" || bad "carry holder: $rc $out"
kreset; printf ': > "%s"; : > "%s"; mv "%s" "%s.x"; cp -Rp "%s.x" "%s"; rm -f "%s"\n' "$T/ps.out" "$T/lsof.out" "$KF" "$KF" "$KF" "$KF" "$T/onstop" > "$T/onstop"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 1 ] && grep -q "^FAILED ka: $KF is not the folder the plan read" <<< "$out" && [ ! -e "$KT" ] && ok "a folder swapped after the plan is not carried" || bad "carry swap: $rc $out"; rm -rf "$KF.x"
kreset; printf ': > "%s"; : > "%s"; mkdir "%s"; rm -f "%s"\n' "$T/ps.out" "$T/lsof.out" "$KF.carry-ka" "$T/onstop" > "$T/onstop"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 1 ] && grep -q "^FAILED ka: $KF.carry-ka is in the way; nothing was moved" <<< "$out" && [ ! -e "$KT" ] && [ -d "$KF/.git" ] && ok "a name in the way stops the carry before anything moves" || bad "carry tmp: $rc $out"; rm -rf "$KF.carry-ka"
kreset; printf ': > "%s"; : > "%s"; chmod 444 "%s/.git"; chmod 555 "%s"; rm -f "%s"\n' "$T/ps.out" "$T/lsof.out" "$KW" "$KW" "$T/onstop" > "$T/onstop"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?; chmod 755 "$KW"; chmod 644 "$KW/.git"
[ $rc -eq 1 ] && grep -qF "but these still do not reach it: $KW" <<< "$out" && grep -q "^MOVED OK ka" <<< "$out" && grep -q "^FAILED: ka: the seat runs in its carried clone, but a linked worktree of it does not reach it" <<< "$out" && ok "a worktree that cannot be repaired fails the run out loud, and the seat still runs" || bad "carry repair: $rc $out"
kreset; kmove "$K/other/ka/main"; ktrust "$K/other/ka/main"; KPO=$T/projects/$(enc "$K/other/ka/main"); rm -rf "$KPO"; printf '{"cwd":"%s"}\n' "$K/other/ka/main" > "$T/claudeadd"; out=$(KR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 0 ] && [ ! -e "$KF" ] && [ -d "$K/other/ka/main/.git" ] && [ "$(git -C "$KW" rev-parse --path-format=absolute --git-common-dir)" = "$K/other/ka/main/.git" ] && [ -f "$KPO/$KS.jsonl" ] && ok "a clone carried into another folder leaves nothing at its old path" || bad "carry elsewhere: $rc $out"
rm -rf "$KPO" "$K/other/ka"
echo "-- an ops seat's plain folder of clones is carried the same way (carry-plain, the Architect's order of 9 Nov 11:28Z)"
PF=$K/org/pa PT=$K/tgt/repo/worktrees/pa PW=$K/ext/pc-wt
preset() { # the seat ka runs in a plain folder holding one clone, pc, with a linked worktree outside and an untracked file, and a loose file
  kreset; rm -rf "$KP"; mkdir -p "$PF" "$K/tgt/repo"; kgit init -q "$PF/pc"; echo c > "$PF/pc/c"; kgit -C "$PF/pc" add c; kgit -C "$PF/pc" commit -qm c
  kgit -C "$PF/pc" worktree add -q "$PW" -b pside 2>/dev/null; echo n > "$PF/notes.txt"; echo u > "$PF/pc/untracked"; PHEAD=$(git -C "$PF/pc" rev-parse HEAD)
  printf '{"seats":[%s]}' "$(row ka ka claude h ka-s "$PF")" > "$T/kchart3.json"; printf 'ka %s carry-plain\n' "$PT" > "$T/kmoves"; ktrust "$PT"
  PP=$T/projects/$(enc "$PF") PPN=$T/projects/$(enc "$PT"); rm -rf "$PP" "$PPN"; mkdir -p "$PP/memory"; echo m > "$PP/memory/MEMORY.md"; echo '{"permissionMode":"auto"}' > "$PP/$KS.jsonl"
  printf 'p9\nn%s\np501\nn%s/pc\n' "$PF" "$PF" > "$T/lsof.out"; printf '{"cwd":"%s"}\n' "$PT" > "$T/claudeadd"
}
PR() { KR --chart "$T/kchart3.json" "$@"; }
preset; out=$(PR --reseat --relaunch --seat ka); grep -q "^RESEAT ka: claude $KS " <<< "$out" && grep -qxF "MOVE ka: from $PF to $PT, carrying the plain folder while the seat is stopped" <<< "$out" && [ ! -e "$K/tgt/repo/worktrees" ] && ok "a ready plain carry is planned, says so, and moves nothing" || bad "plain plan: $out"
grep -qxF "WRONG ka (claude): not yet carried to $PT; the carry is ready" <<< "$(PR --check --seat ka)" && ok "--check names a plain carry still to run" || bad "plain check: $(PR --check --seat ka)"
kreset; kmove "$KT" carry-plain; grep -q "^UNRESOLVED ka: $KF is in git, and only a folder outside git is carried plain" <<< "$(KP1)" && ok "a clone is never carried plain" || bad "plain clone: $(KP1)"
preset; kgit -C "$PF/pc" worktree add -q "$PF/inner" -b inner 2>/dev/null; grep -q "^UNRESOLVED ka: $PF/inner/.git is not a .git folder: a linked worktree or submodule" <<< "$(PR --reseat --relaunch --seat ka)" && ok "a linked worktree inside the folder is refused" || bad "plain inner: $(PR --reseat --relaunch --seat ka)"
preset; mkdir -p "$PF/fake/.git"; grep -q "^UNRESOLVED ka: $PF/fake is not an ordinary clone with its own .git" <<< "$(PR --reseat --relaunch --seat ka)" && ok "a .git folder that is not a clone is refused" || bad "plain fake: $(PR --reseat --relaunch --seat ka)"
preset; git -C "$PF/pc" config zeo.path "$PF/x"; grep -q "^UNRESOLVED ka: its git config names its own path" <<< "$(PR --reseat --relaunch --seat ka)" && ok "a clone whose config names the folder is refused" || bad "plain config: $(PR --reseat --relaunch --seat ka)"
preset; mkdir -p "$PT"; kgit init -q "$PT"; grep -q "^UNRESOLVED ka: $PT is there, but it is not a carried plain folder outside git" <<< "$(PR --reseat --relaunch --seat ka)" && ok "a new path that is there and in git is refused" || bad "plain there: $(PR --reseat --relaunch --seat ka)"
preset; printf ': > "%s"; : > "%s"; git init -q "%s/new"; rm -f "%s"\n' "$T/ps.out" "$T/lsof.out" "$PF" "$T/onstop" > "$T/onstop"; out=$(PR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 1 ] && grep -q "^FAILED ka: the clones in $PF are not the ones the plan read; nothing was moved" <<< "$out" && [ ! -e "$PT" ] && [ -f "$PP/$KS.jsonl" ] && ok "a clone added after the plan: nothing moves" || bad "plain swap: $rc $out"
# the check after the rename: an mv that leaves another folder there, or another commit in a clone, is caught before the seat starts
mkdir -p "$T/mvbin"; cat > "$T/mvbin/mv" <<MV
#!/bin/bash
/bin/mv "\$@" || exit
[ "\$2" = "$PT" ] || exit 0
if [ -f "$T/mvbin/copy" ]; then cp -Rp "\$2" "\$2.c" && /bin/mv "\$2" "\$2.gone" && /bin/mv "\$2.c" "\$2"; fi
if [ -f "$T/mvbin/commit" ]; then git -c user.email=t@t -c user.name=t -C "\$2/pc" commit -q --allow-empty -m x; fi
MV
chmod +x "$T/mvbin/mv"
for how in copy commit; do preset; : > "$T/mvbin/$how"; out=$(PATH="$T/mvbin:$PATH" PR --reseat --relaunch --apply --seat ka); rc=$?; rm -f "$T/mvbin/$how"
  [ $rc -eq 1 ] && grep -q "^FAILED ka: $PT does not read as the same folder with the same clones after the move; it was not started" <<< "$out" && ! grep -q '^RESUMED ka' <<< "$out" || bad "plain verify $how: $rc $out"; done
ok "a folder that is not the same one after the rename, or a clone at another commit, fails the carry and the seat is not started"
rm -rf "$K/tgt" "$PW"
preset; pi=$(stat -f %i "$PF"); rm -f "$T/launched"; out=$(PR --reseat --relaunch --apply --seat ka); rc=$?
[ $rc -eq 0 ] && grep -qxF "CARRIED ka: $PF to $PT, the same plain folder (inode $pi) with its 1 clones, each at the same commit; 1 linked worktrees elsewhere repaired" <<< "$out" && grep -q "^MOVED OK ka: session $KS, one transcript, one process, in $PT" <<< "$out" && ok "the plain carry runs: the folder moves, its clone's worktree is repaired, the move is proved" || bad "plain apply: $rc $out"
[ "$(stat -f %i "$PT")" = "$pi" ] && [ "$(git -C "$PT/pc" rev-parse HEAD)" = "$PHEAD" ] && [ -f "$PT/notes.txt" ] && [ -f "$PT/pc/untracked" ] && [ ! -e "$PF" ] && [ "$(stat -f %Lp "$K/tgt/repo/worktrees")" = 755 ] && ok "the same folder, its clone, commit and files are at the new path; the old path is gone; worktrees/ was made" || bad "plain carried: $(ls -A "$K/org")"
[ "$(git -C "$PW" rev-parse --path-format=absolute --git-common-dir)" = "$PT/pc/.git" ] && git -C "$PW" status --porcelain >/dev/null && ok "the clone's linked worktree outside reaches it at its new place" || bad "plain repair: $(git -C "$PW" rev-parse --git-common-dir 2>&1)"
[ -f "$PPN/$KS.jsonl" ] && [ -f "$PPN/memory/MEMORY.md" ] && [ ! -e "$PP" ] && grep -qF -- "-c $PT -- $HERE/seat-exec.sh ka claude" "$T/launched" && ok "its project went with it, and it started in the new folder" || bad "plain project: $(ls "$T/projects") $(cat "$T/launched")"
grep -q "^OK ka (claude)" <<< "$(PR --check --seat ka)" && grep -q '^OK ka: started by rescue, right already' <<< "$(PR --reseat --relaunch --seat ka)" && ok "after the plain carry it checks right, and a second run leaves it alone" || bad "plain after: $(PR --check --seat ka)"
rm -rf "$K/tgt" "$PW"
kreset; reset_live; rm -f "$T/onstop" "$T/pstree" "$T/claudeadd"; : > "$T/ps.out"; : > "$T/lsof.out"; : > "$T/panes"; printf '' > "$T/psE.out"

echo "-- a check reads all its input: under pipefail a reader that leaves early turns a match into a miss"
pad() { printf '%s\n' "$1"; head -c 1000000 /dev/zero | tr '\0' x; echo; }
hits=$(grep -nE '\| *(/usr/bin/)?grep +(-[a-zA-Z]+ +)*-[a-zA-Z]*q' "$HERE/rescue.sh" "$HERE/model-answered.sh" "$HERE/normalise-clone.sh")
[ -z "$hits" ] && ok "no script pipes into grep -q" || bad "pipes into grep -q: $hits"
reset_live; echo cx-maintainer >> "$T/live"; echo 'cx-maintainer|%8|800||codex' > "$T/panes"
echo "800 /x/codex resume -a never -s danger-full-access -C $T/w/cx --no-daemon 44444444-4444-4444-8444-444444444444 p" > "$T/ps.out"
pad '  Working (9s, esc to interrupt)' > "$T/screen"
grep -q '^WORK cx: a turn is in progress' <<< "$(R --reseat --seat cx 2>&1)" && ok "a turn is found on a screen larger than the pipe" || bad "big screen"
pad '  Trust this folder? Codex can read, edit, and run files here' > "$T/screen"
echo 'cx-maintainer|%8|800|1|codex' > "$T/panes"
grep -q 'waiting at the trust prompt' <<< "$(R --check --seat cx 2>&1)" && ok "a seat at the trust screen is found the same way" || bad "big trust"
rm -f "$T/screen"; reset_live
echo "700 /x/codex resume 44444444-4444-4444-8444-444444444444" > "$T/ps.out"; pad "n$T/w/cx" > "$T/lsof.out"
grep -q '^RUNNING cx:' <<< "$(R --seat cx 2>&1)" && ok "a process in the folder is found in a long lsof answer, so no second writer starts" || bad "big lsof"
: > "$T/lsof.out"; : > "$T/ps.out"; reset_live

echo "-- the chart and usage"
grep -q 'WARNING.*last good' <<< "$(R --chart "$T/gone.json" 2>&1)" && ok "an unreadable chart falls back to the last good one, out loud" || bad "fallback"
rm -f "$T/state/ORG-CHART.last-good.json"; R --chart "$T/gone.json" >/dev/null 2>&1; [ $? -eq 1 ] && ok "no chart at all is a failure" || bad "no chart"
"$HERE/rescue.sh" --socket '../x' >/dev/null 2>&1; [ $? -eq 2 ] && ok "a bad socket name is usage" || bad "bad socket"
"$HERE/rescue.sh" --check --apply >/dev/null 2>&1; [ $? -eq 2 ] && ok "--check never combines with --apply" || bad "check apply"

echo "-- model-answered.sh: an answer from the model after the seat's own start, not a process, proves a restart"
MA=$T/ma; mkdir -p "$MA/s/2026/11/10" "$MA/p/-k"
MR() { ZEO_RESCUE_CODEX_SESSIONS="$MA/s" ZEO_RESCUE_PROJECTS="$MA/p" ZEO_RESCUE_ANSWER_PAUSE=0 "$HERE/model-answered.sh" "$@" 2>&1; }
AT=' at 2050-01-01T00:00:00Z' CL='"model":"claude-test"'
printf 'RESUMED cxa: codex aaaa-1 (x) in a%s\nRESUMED cxe: codex aaaa-2 (x) in e%s\nRESUMED cla: claude bbbb-1 (x) in c%s\n' "$AT" "$AT" "$AT" > "$MA/run.log"
printf '{"timestamp":"2099-01-01T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant"}}\n' > "$MA/s/2026/11/10/rollout-2026-11-10T00-00-00-aaaa-1.jsonl"
printf '{"timestamp":"2000-01-01T00:00:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant"}}\n{"timestamp":"2099-01-01T00:00:01.000Z","type":"event_msg","payload":{"type":"task_complete","error":{"message":"Error running remote compact task: {\\"detail\\":\\"The \x27gpt-6.1-sol\x27 model requires a newer version of Codex.\\"}"}}}\n' > "$MA/s/2026/11/10/rollout-2026-11-10T00-00-00-aaaa-2.jsonl"
printf '{"timestamp":"2099-01-01T00:00:01.000Z","type":"assistant","message":{%s}}\n' "$CL" > "$MA/p/-k/bbbb-1.jsonl"
out=$(MR "$MA/run.log"); rc=$?
echo "$out" | grep -qxF 'ANSWERED cxa (codex)' && echo "$out" | grep -qxF 'ANSWERED cla (claude)' && ok "an assistant message after the seat's start is an answer, for both harnesses" || bad "answered: $out"
echo "$out" | grep -qxF "ERROR cxe (codex): The 'gpt-6.1-sol' model requires a newer version of Codex." && [ $rc -eq 1 ] && ok "a turn that ended in an error is shown, an answer from before the start does not count, and it exits 1" || bad "error: $rc $out"
printf 'RESUMED cla: claude bbbb-1 (x) in c%s\n' "$AT" > "$MA/one.log"
printf '{"timestamp":"2050-01-01T00:00:00.900Z","type":"assistant","message":{%s}}\n' "$CL" > "$MA/p/-k/bbbb-1.jsonl"
out=$(MR "$MA/one.log"); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -qxF 'WAITING cla (claude)' && ok "a record in the start's own second is not taken for an answer: the old process may have written it" || bad "same second: $rc $out"
printf '{"timestamp":"2099-01-01T00:00:01.000Z","type":"assistant","message":{"model":"<synthetic>","content":[{"text":"No response requested."}]}}\n' > "$MA/p/-k/bbbb-1.jsonl"
out=$(MR "$MA/one.log"); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -qxF 'WAITING cla (claude)' && ok "Claude's own synthetic message is not an answer from the model" || bad "synthetic: $rc $out"
printf '{"timestamp":"2099-01-01T00:00:01.000Z","type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"text":"API Error: 400"}]}}\n' > "$MA/p/-k/bbbb-1.jsonl"
out=$(MR "$MA/one.log"); rc=$?; [ $rc -eq 1 ] && echo "$out" | grep -q '^ERROR cla (claude)' && ok "a Claude API error message is an ERROR, not an answer" || bad "claude api error: $rc $out"
printf '{"timestamp":"2099-01-01T00:00:01.000Z","type":"assistant","message":{%s}}\n{"timestamp":"2099-01-01T00:00:09.000Z","type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[{"text":"API Error: 401"}]}}\n' "$CL" > "$MA/p/-k/bbbb-1.jsonl"
out=$(MR "$MA/one.log"); rc=$?; [ $rc -eq 1 ] && echo "$out" | grep -q '^ERROR cla (claude)' && ok "an error after an answer wins: the newest verdict counts" || bad "later error: $rc $out"
printf '{"timestamp":"2099-01-01T00:00:01.000Z","type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>"}}\n{"timestamp":"2099-01-01T00:00:09.000Z","type":"assistant","message":{%s}}\n' "$CL" > "$MA/p/-k/bbbb-1.jsonl"
out=$(MR "$MA/one.log"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -qxF 'ANSWERED cla (claude)' && ok "and an answer after an error wins too" || bad "later answer: $rc $out"
printf 'RESUMED cla: claude bbbb-1 (x) in c%s\nSTOPPED: cla: its process says another session; no other seat was started\n' "$AT" > "$MA/stop.log"
out=$(MR "$MA/stop.log"); rc=$?; [ $rc -eq 1 ] && echo "$out" | grep -q '^STOPPED cla (claude): the run stopped it again' && ! echo "$out" | grep -q '^ANSWERED' && ok "a seat the run stopped again after its start is STOPPED, not ANSWERED, and exits 1" || bad "stopped: $rc $out"
printf 'RESUMED cla: claude bbbb-1 (x) in c\n' > "$MA/old.log"; out=$(MR "$MA/old.log"); rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q '^NO START TIME cla' && ! echo "$out" | grep -q '^ANSWERED' && ok "a RESUMED line with no start time is never judged" || bad "no time: $rc $out"
printf 'RESUMED gone: codex cccc-9 (x) in g%s\n' "$AT" > "$MA/gone.log"; out=$(MR "$MA/gone.log"); rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q '^NO RECORD gone' && ok "a seat with no record found exits 3" || bad "no record: $rc $out"
printf 'OK x: started by rescue, right already\n' > "$MA/none.log"; out=$(MR "$MA/none.log"); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'no answer to wait for' && ok "a run that restarted nothing has nothing to wait for" || bad "none: $rc $out"
echo; [ $fails -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
