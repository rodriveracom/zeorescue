# zeorescue

The rescue seat of zeroemployeeorg: `zeo-rescue`. When the system collapses or there is an emergency, run this, and nothing else:

```
cd <code-root>/zeroemployeeorg/zeorescue/main && claude
```

- `AGENTS.md`: who the seat is, its boot sequence and its rules.
- `STATE.md`: its memory: what happened last, what is open, what to do next. It is a private record, outside this public repository; `AGENTS.md` says where the seat finds it.
- `~/.local/state/zeo-rescue/`: the host's private inputs: `ORG-CHART.json` (or a link to the live chart), `host-name`, `session-pins`, `folder-moves`, `seat-markers`, `records-path`.
- `RUNBOOK.md`: the same recovery by hand, with no agent.
- `rescue.sh`, `seat-exec.sh`: the mechanism. `make help` lists the commands.

It is on-demand on purpose, neither a daemon nor a service: anything resident would die in the same teardown.
