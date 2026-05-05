# Shuttle — Agent Notes

Local OTP-supervised dispatcher for felt constitution workers. Polls the felt
tree, launches one tmux worker per eligible fiber, exposes a snapshot surface
for Portolan and other consumers.

**Status: Stages 0–6 complete; Stage 7 (BEAM distribution / SSH-drop resilience) deferred.**
The Elixir engine is the production dispatcher; portolan's TS engine is retired.
See [[ai-futures/shuttle/constitution-shuttle-standalone]] for the canonical invariants.

The repo has no git remote — local-only, like portolan. Don't add one without intent.

## Build + lifecycle

The escript loads its BEAMs at boot, so editing source has zero effect on a
running daemon until you restart. Use the Makefile:

```
make build      # mix escript.build → bin/shuttle (MIX_ENV=dev)
make start      # nohup detached; logs → ~/Library/Logs/shuttle.log
make stop       # SIGTERM with 5s grace
make restart    # build + stop + start (the load-bearing daemon target)
make cli        # go build → ~/go/bin/shuttle-ctl (load-bearing CLI target)
make all        # restart + cli (everything)
make logs       # tail -f the log
make status     # shuttle-ctl ps + snapshot summary
make clean      # rm _build and stray Elixir.*.beam at project root
```

**Two artifacts, two languages, two release cadences.** The Elixir daemon
(`bin/shuttle`) and the Go CLI (`~/go/bin/shuttle-ctl`) are independent —
rebuilding one never implies rebuilding the other. Editing `cmd/shuttle/*.go`
needs `make cli`; editing `lib/shuttle/*.ex` needs `make restart`. When the
kanban or any portolan path starts shelling out to a new shuttle-ctl verb,
`make cli` becomes load-bearing — a stale binary breaks transitions
silently. See
[[ai-futures/portolan/gotchas/gotcha-shuttle-ctl-binary-stale-after-source-update]].

**`bin/shuttle` is an escript** — it bundles BEAM bytecode at build time and loads it at boot. A restart without `make build` is a no-op for picking up source edits; `mix compile` without restart is a no-op for an already-running daemon. **`make restart` always.** When `shuttle-ctl status` sees a fiber but `bin/shuttle snapshot` doesn't list it as eligible, the daemon is stale.

Default `MIX_ENV=dev` matches the localhost:4000 endpoint config in
`config/dev.exs`. The Phoenix endpoint binds 127.0.0.1:4000 only when
`server: true` is set there — don't propagate that to other envs.

If `mix escript.build` warns about "redefining module Shuttle.X" with the
"current version loaded from Elixir.Shuttle.X.beam" hint, run `make clean`
first — stray `.beam` files at the project root shadow the real ones. They
should never be committed.

## Quick start — operating without rebuilding

```bash
bin/shuttle snapshot                          # JSON snapshot of daemon state
bin/shuttle dispatch <fiber-id>               # one-shot dispatch

# shuttle-ctl — agent-facing CLI; offline; schema-validating
shuttle-ctl status                            # all fibers with shuttle: blocks
shuttle-ctl status --all                      # local + every configured remote (via daemon /state/composite)
shuttle-ctl status --remote candide           # single remote, filtered from the composite snapshot
shuttle-ctl ps                                # live tmux workers only
shuttle-ctl install <fiber> [-m <agent-id>] [--disabled]
shuttle-ctl repeat <fiber> --schedule "0 9 * * 1-5" --tz Europe/Paris
shuttle-ctl pause / resume / accept <fiber>
shuttle-ctl set-model <fiber> <agent-id>
shuttle-ctl abort / attach <fiber>
shuttle-ctl migrate --dry-run                 # preview eligibility migration
```

## Critical invariants

- **tmux owns the worker process; Shuttle owns the watcher.** Workers stay attachable via `tmux attach -t shuttle-<fiber-id>`. Supervise watchers, not workers.
- **Felt is the data layer; Shuttle shells out to the felt CLI.** Don't import felt internals.
- **Agent records live in one source of truth: `share/agents.json`.** Both runtimes (Elixir daemon, Go CLI) embed it at compile time — Elixir via `@external_resource` + `File.read!` in `lib/shuttle/agents.ex`, Go via `//go:embed` (generated `pkg/schema/agents_embedded.go`). Edit the JSON, then `make restart`. There is no `config/agents.exs` and no hand-edited fallback list anywhere — see `[[ai-futures/shuttle/finding-agent-registry-four-mirrors]]` for the cleanup that landed.
- **`shuttle.agent` field drives agent selection.** The `shuttle:` block's `agent:` field resolves against the registry. Bare `codex`/`pi` felt tags resolve via back-compat aliases when no `shuttle.agent` is set; default agent is `claude-sonnet`.
- **shuttle-ctl is the agent-facing CLI.** Write verbs validate before write; works offline. Elixir `bin/shuttle` handles daemon lifecycle and dispatch only.
- **No tag predicate for dispatch.** `constitution` is a human convention only — a fiber with a `shuttle:` block dispatches with or without it. Tags are free-form qualitative noticings; only `idea` is read by Portolan's kanban (for column placement).

## How dispatch works

- **Poller** (`lib/shuttle/poller.ex`) is the single GenServer that owns the
  tick. It walks each configured `felt_host`, parses each `*.md` file's
  frontmatter, and considers a fiber eligible iff `shuttle.enabled: true` AND
  `status in ["open", "active"]` AND not already running/claimed AND deps
  satisfied.
- **Configured hosts** come from `LOOM_HOMES` (comma-separated) →
  persisted `~/.shuttle/felt_hosts.json` → `LOOM_HOME` → default `~/loom`.
  `POST /api/v1/felt-hosts` rewrites the persisted file; earlier-configured
  hosts win on fiber-id collisions across hosts.
- **Dispatcher** (`lib/shuttle/dispatcher.ex`) resolves the agent via
  `Shuttle.Agents.resolve_by_name/1` against the embedded registry, spawns
  `shuttle-<fiber-id>` tmux session.
- **Standing roles** are recurring fibers — `shuttle.kind: standing` with a
  cron `schedule:`. Daemon dispatches only when `next_due_at` is due AND
  `review.state` is `scheduled` or `accepted`. Worker exit flips state to
  `awaiting`; `shuttle-ctl accept` advances `next_due_at`.

## Inspecting state

```
make status                              # daemon-side view (ps + snapshot)
shuttle-ctl status                       # Go walker view (independent of daemon)
shuttle-ctl status -j                    # JSON
bin/shuttle snapshot                     # raw JSON snapshot
~/Library/Logs/shuttle.log               # daemon stdout/stderr
tmux ls | grep '^shuttle-'               # live workers
curl -s http://127.0.0.1:4000/api/v1/agents | jq   # agent registry as JSON
curl -s http://127.0.0.1:4000/api/v1/state | jq    # full orchestrator state
curl -s http://127.0.0.1:4000/api/v1/state/composite | jq   # local + per-remote snapshots
```

**Cross-host visibility.** `--all` and `--remote` go through the local
daemon's `/api/v1/state/composite`; the daemon's `RemoteRegistry` polls
each configured remote (`config :shuttle, :remotes, [...]`) over its
SSH-tunnel-mapped port and merges the snapshots with freshness flags.
The CLI never talks to remote daemons directly — `SHUTTLE_DAEMON_URL`
overrides which local daemon to query, but remote URLs live in mix
config alone. See [[ai-futures/shuttle/constitution-shuttle-remote-dispatch]].

## Dispatch prompt structure

The fresh, resume, and standing-run prompts all share the same shape (`compose_prompt/3` in `lib/shuttle/dispatcher.ex`):

1. **Orientation paragraph** — what Shuttle is, what the worker is here to do, how the practice loads. Per-prompt, not boilerplate. Goes first because in causal attention every downstream token sees the prefix.
2. **`Fiber: <id>`** (and `Run: <run-id>` for standing) — identity lines, grep-able.
3. **`From User · <relative time>`** — the most recent `--kind review-comment` event, if any. Pulled fresh at dispatch. The user's intent, inlined so it sits in attention prefix.

The fiber's outcome and last editorial event are *not* inlined — they're already in scope after `felt show <id>` (outcome + Recent line) and `felt history <id>` (full chain), which the shuttle skill prescribes the worker calls on arrival. Inlining either duplicates state and risks drift between the prompt's snapshot and felt's view.

Operational instructions (read the constitution, exit before half-full, append an editorial event, `kill $PPID`, standing-run awaiting-review handoff) live in the `shuttle` and `felt` skills, not the prompt. The prompt's job is orientation; duplicating practice means drift.

A useful sanity ladder when something isn't dispatching:

1. `shuttle-ctl status` shows `enabled: true, idle, oneshot`? → fiber is well-formed and the Go walker sees it.
2. `bin/shuttle snapshot` lists it under `eligible[]` with `state: running`? → daemon dispatched it.
3. If shuttle-ctl sees it but daemon doesn't → daemon binary is stale. `make restart`.
4. If daemon sees it but agent never appears → check `share/agents.json` for the resolved agent's `cli` and that the wrapper is on `PATH`.
5. If the snapshot has no `felt_hosts:` field → binary pre-`297a24d`. Same fix: `make restart`.

## Codebase layout

```
shuttle/                     project root (this dir, flat — no nested shuttle/)
├── CLAUDE.md                you're reading it
├── Makefile                 build + daemon lifecycle
├── mix.exs                  Mix project
├── bin/shuttle              the daemon escript (built artifact)
├── lib/                     Elixir source
│   ├── shuttle/poller.ex    discover + eligibility + retry queue
│   ├── shuttle/dispatcher.ex  agent resolution, tmux launch, session-UUID capture
│   ├── shuttle/agents.ex    agent registry — reads share/agents.json at compile time
│   └── shuttle_web/         agent-API HTTP endpoints (/api/v1/...)
├── cmd/shuttle/             Go CLI (shuttle-ctl)
├── pkg/schema/              Go schema package (types, validation, YAML I/O)
│   ├── agents.go            registry loader (//go:embed agents_embedded.go)
│   └── agents_embedded.go   generated — embeds share/agents.json bytes
├── share/                   shared data (canonical for both runtimes)
│   ├── agents.json          THE agent registry — single source of truth
│   └── schema.json          shuttle: block frontmatter schema
├── config/                  Elixir env config (dev/test/prod endpoint settings)
├── test/                    Mix test suite
└── deps/, _build/           Mix-managed; gitignored
```

## Tests

```
mix test                   # full Elixir suite (78 tests, ~7s)
mix test --only focus      # tagged subset
go test ./pkg/schema/...   # Go schema tests
```

Disk-walking tests use real fixture directories under `test/support/` rather
than mocks — the walker is a thin filesystem read so this is faster and
catches more.

## Pointers

- Constitution: `felt show ai-futures/shuttle/constitution-shuttle-standalone`
- SPEC: `~/loom/.felt/ai-futures/shuttle/SPEC.md`
- Agent registry: `share/agents.json` (single source of truth — see invariants above)
- Loom shell wrappers: `~/loom/shell-functions.sh` (claude, codex, pi, kimi, glm)
- Shuttle skill: `~/.claude/skills/shuttle/SKILL.md`
- Fibers: `ai-futures/shuttle/` in `~/loom/.felt/` — design fibers, constitutions (cutover, multi-host, CLI, etc.), gotchas, postmortems.
