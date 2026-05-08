# Shuttle — Contributor Notes

Local OTP-supervised dispatcher for felt constitution workers. Polls the felt
tree, launches one tmux worker per eligible fiber, exposes a snapshot surface
for dashboards and other consumers.

The Elixir daemon is the production dispatcher.

## Build + lifecycle

The escript loads its BEAMs at boot, so editing source has zero effect on a
running daemon until you restart. Use the Makefile:

```
make build      # mix escript.build → bin/shuttle (MIX_ENV=dev)
make start      # nohup detached; logs → ~/Library/Logs/shuttle.log (macOS)
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
needs `make cli`; editing `lib/shuttle/*.ex` needs `make restart`.

**`bin/shuttle` is an escript** — it bundles BEAM bytecode at build time and
loads it at boot. A restart without `make build` is a no-op for picking up
source edits. `make restart` always.

**Portolan owns the normal local production surface.** In Cail's everyday
setup, `~/Documents/projects/portolan/dev.sh` starts Portolan's frontend,
backend, and Shuttle daemon together (`bin/shuttle start` on port 4000), and
`bash dev.sh kill` tears down all three ports. If you are restarting the live
stack the human is using, prefer the Portolan script so Shuttle is not left as
a stray standalone daemon fighting Portolan's process lifecycle. Use
`make restart` for Shuttle-only daemon development, then restart Portolan's
`dev.sh` stack when the browser-facing app should pick up the rebuilt daemon.

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
shuttle-ctl status --all                      # local + every configured remote
shuttle-ctl status --remote <name>            # single remote
shuttle-ctl ps                                # live tmux workers only
shuttle-ctl install <fiber> --project-dir "$PWD" [-m <agent-id>] [--disabled]
shuttle-ctl repeat <fiber> --schedule "0 9 * * 1-5" --tz Europe/Paris --project-dir "$PWD"
shuttle-ctl pause <fiber>                       # disable + kill live worker; --no-kill preserves it
shuttle-ctl resume / accept <fiber>
shuttle-ctl set-model <fiber> <agent-id>
shuttle-ctl dispatch <fiber>
shuttle-ctl snapshot
shuttle-ctl abort / attach <fiber>
shuttle-ctl migrate --dry-run                 # preview eligibility migration
```

## Critical invariants

- **tmux owns the worker process; Shuttle owns the watcher.** Workers stay
  attachable via `tmux attach -t shuttle-<fiber-id>`. Supervise watchers,
  not workers.
- **Felt is the data layer; Shuttle shells out to the felt CLI.** Don't
  import felt internals.
- **Agent records live in one source of truth: `share/agents.json`.** Both
  runtimes (Elixir daemon, Go CLI) embed it at compile time — Elixir via
  `@external_resource` + `File.read!` in `lib/shuttle/agents.ex`, Go via
  `//go:embed` (generated `pkg/schema/agents_embedded.go`). Edit the JSON,
  then `make restart`. There is no `config/agents.exs`.
- **`shuttle.agent` field drives agent selection.** The `shuttle:` block's
  `agent:` field resolves against the registry. Default agent is
  `claude-sonnet`.
- **`shuttle.host` field drives daemon affinity.** Absent or empty means
  `local`; each daemon only dispatches fibers whose `host:` matches its
  configured `config :shuttle, :host`.
- **`shuttle.project_dir` is required for enabled installs.** `shuttle-ctl
  install` and `repeat` require `--project-dir`; workers start there instead
  of falling back to the felt store.
- **shuttle-ctl is the agent-facing CLI.** Local write verbs validate before
  write and work offline. Cross-host writes belong to Portolan's kanban/API
  surface, not to `shuttle-ctl`. `bin/shuttle` handles daemon lifecycle and
  dispatch.
- **No tag predicate for dispatch.** The `shuttle:` block's `enabled: true`
  field is the dispatch signal. Tags are free-form qualitative noticings;
  only `idea` is load-bearing for Portolan's kanban column placement.

## How dispatch works

- **Poller** (`lib/shuttle/poller.ex`) owns the tick. It walks each
  configured felt host, pulls candidate metadata via `felt ls --json` and
  per-fiber detail via `felt show -j`, and considers a fiber eligible iff
  `shuttle.enabled: true` AND `status in ["open", "active"]` AND not
  already running AND deps satisfied.
- **Configured hosts** come from `LOOM_HOMES` (comma-separated env var) →
  persisted `~/.shuttle/felt_hosts.json` → `LOOM_HOME` → `~/loom`.
  `POST /api/v1/felt-hosts` rewrites the persisted file.
- **Dispatcher** (`lib/shuttle/dispatcher.ex`) resolves the agent via
  `Shuttle.Agents.resolve_by_name/1` against the embedded registry, spawns
  `shuttle-<fiber-id>` tmux session.
- **Standing roles** — `shuttle.kind: standing` with a cron `schedule:`.
  Scheduled runs dispatch only when `next_due_at` is due AND `review.state`
  is `scheduled` or `accepted`. Manual dispatch is ad-hoc (`adhoc-...`
  run id) and preserves `next_due_at`; worker exit flips state to
  `awaiting`, and `shuttle-ctl accept` advances `next_due_at` only for
  scheduled runs.

## Dispatch prompt structure

All prompt variants share this shape (`compose_prompt/3` in dispatcher.ex):

1. **Orientation paragraph** — what Shuttle is, what the worker is here to
   do, how the practice loads. Per-prompt, not boilerplate. Goes first
   because in causal attention every downstream token sees the prefix.
2. **`Fiber: <id>`** (and `Run: <run-id>` for standing) — identity lines.
3. **`From User · <relative time>`** — the most recent `--kind
   review-comment` event, if any. Pulled fresh at dispatch.

The fiber's outcome and last editorial event are not inlined — they're
already in scope after `felt show <id>` and `felt history <id>`, which
the shuttle skill prescribes the worker calls on arrival.

## Inspecting state

```bash
shuttle-ctl status                       # Go walker view (independent of daemon)
bin/shuttle snapshot                     # raw JSON snapshot
make status                              # daemon-side view (ps + snapshot)
~/Library/Logs/shuttle.log               # daemon stdout/stderr (macOS)
tmux ls | grep '^shuttle-'               # live workers
curl -s http://127.0.0.1:4000/api/v1/agents | jq
curl -s http://127.0.0.1:4000/api/v1/state | jq
curl -s http://127.0.0.1:4000/api/v1/state/composite | jq
```

Dispatch sanity ladder:

1. `shuttle-ctl status` shows `enabled: true, idle, oneshot`? → fiber is
   well-formed and the Go walker sees it.
2. `bin/shuttle snapshot` lists it under `eligible[]`? → daemon dispatched.
3. shuttle-ctl sees it but daemon doesn't → daemon binary is stale.
   `make restart`.
4. Daemon sees it but agent never appears → check `share/agents.json` for
   the resolved agent's `cli` and that the wrapper is on `PATH`.

## Codebase layout

```
shuttle/
├── AGENTS.md                canonical agent-facing guide
├── CLAUDE.md                compatibility pointer to AGENTS.md
├── Makefile                 build + daemon lifecycle
├── mix.exs                  Mix project
├── bin/shuttle              the daemon escript (built artifact)
├── lib/                     Elixir source
│   ├── shuttle/poller.ex    discover + eligibility + retry queue
│   ├── shuttle/dispatcher.ex  agent resolution, tmux launch
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

```bash
mix test                   # full Elixir suite (110 tests, ~7s)
mix test --only focus      # tagged subset
go test ./pkg/schema/...   # Go schema tests
```

## Contributing

See `CONTRIBUTING.md`.
