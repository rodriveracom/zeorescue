# zeo-rescue runbook

The org's recovery path, as a recovery console is to an operating system: needed only when the system is down, and asleep the rest of the time.

## When the system collapses

```
cd <code-root>/zeroemployeeorg/zeorescue/main && claude
```

`<code-root>` is the host's code folder. That is all the operator has to remember. The seat boots from `AGENTS.md` and its private `STATE.md`. Over a connection that may drop, use `make agent` instead: it starts the seat detached on its own tmux socket, and `tmux -L zeo-rescue attach` reaches it.

Without an agent, the steps below work by hand.

## Seats are gone

`tmux -L zeo2 ls` says no server, or far fewer sessions than the org chart has.

1. `make plan`. It starts nothing. Every seat on this host gets one line: `LIVE`, `RUNNING`, `RESUME` or `UNRESOLVED`, with its session, mode and git marker.
2. Check that each `RESUME` line names the seat's own session. The newest transcript in a directory is assumed to be the seat's. If someone ran another session there, pin the right one in `~/.local/state/zeo-rescue/session-pins`. A seat `UNRESOLVED` for "no recorded git marker" needs a line `SEAT MARKER` in `~/.local/state/zeo-rescue/seat-markers` (master, sparring, principal or inactive), and only on the Architect's word.
3. Prove one seat first: `make rescue ARGS='--seat SOME-SEAT'`, then `make check ARGS='--seat SOME-SEAT'`. Pick a seat recorded as `master` whose id is not in any fault.
4. `make rescue`. Seats start 20 seconds apart. The first of each harness must prove its identity, marker and git, or the run stops.
5. `make check`. It must end `check: ok N, wrong 0`. Once a run has ended, `make rescue` can run again: a seat that is up is left alone. Never run two at once: an `--apply` run holds `~/.local/state/zeo-rescue/apply.lock`, and a second one refuses with `LOCKED` while the first runs. `STALE LOCK` means a run ended without letting it go (it was killed, or the host went down): check that no rescue runs (`pgrep -fl rescue.sh`), then add `--break-stale-lock` to `ARGS` once.
6. For `UNRESOLVED`, ask the rescue seat, or fix the named cause.

## Seats are up, but wrong

`make check` says `WRONG`, or seats report that git fails, or `zmsg whoami` names another seat.

1. `make reseat-plan`. Add `--before YYYYMMDDHHMM` to `ARGS` if the fault wrote shell snapshots, so markers come from before it.
2. Prove one seat: `make reseat ARGS='--seat SOME-SEAT ...'`, then `make check ARGS='--seat SOME-SEAT'`.
3. `make reseat`, then `make check`. All harnesses stop first, then the shared Codex daemon by exact pid, and only then does any seat start, so no thread ever has two writers. Seats started by rescue carry `@zeo_rescue` and are left alone, so it can be run again once the first run has ended.

A reseat interrupts every seat it touches, so give each one a `--note-file` saying why. `WORK` lines in the plan and in the run's log name what a restart cuts: a turn on the screen, a tool shell, or a tool under the shared daemon. They inform; they do not stop the run.

A bulk `make reseat` also resumes any seat that is dead, with the same note. A seat that needs its own note goes first, alone.

**If it stops.** `FAILED SEAT: pid N still holds its rollout` means something has that thread open, usually the shared daemon: starting the seat would make two writers, so it stays down on a sleep. `FAILED SEAT: who holds its rollout cannot be read (lsof ...)` and `which processes work in ... cannot be read` mean the question failed, so nothing was started or moved: fix lsof first. `FAILED SEAT: its session ... appeared after the plan`, `a process holds its session ... now` or `exists already` mean something else started the seat while the run was going: it is left alone, never killed or started twice. `STOPPED: ...` means the first seat of a harness failed its proof: that seat is stopped again and loses `@zeo_rescue`, and `RECOVERY:` counts what is down. In both cases the threads are intact and every stopped seat is on a sleep. Start none by hand. Fix the cause, then run the same line again: seats on a sleep are planned again, and a seat whose sleep ran out comes back as `RESUME`.

## Finding the cause

`make teardown-log ARGS="'START' 'END'"` writes the system log to `~/.local/state/zeo-rescue/` (it asks for the sudo password). Nobody needs to read it or paste it: the rescue seat reads the file. Run it soon after a crash, because the log does not keep `--info` for long.

## Stuck seats

`make check` names a seat at the Claude trust prompt. Only the operator answers it, by attaching: `tmux -L zeo2 attach -t SESSION` (no leading `=` outside quotes: zsh reads it as a command lookup).
