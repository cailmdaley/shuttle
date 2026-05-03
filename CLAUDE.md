# Shuttle — Agent Notes

Local OTP-supervised dispatcher for felt constitution workers. Polls the felt
tree, launches one tmux worker per eligible fiber, exposes a snapshot surface
for Portolan and other consumers.

## Build + lifecycle

The escript loads its BEAMs at boot, so editing source has zero effect on a
running daemon until you restart. Use the Makefile:

```
make build      # mix escript.build → bin/shuttle (MIX_ENV=dev)
make start      # nohup detached; logs → ~/Library/Logs/shuttle.log
make stop       # SIGTERM with 5s grace
make restart    # build + stop + start (the load-bearing one)
make logs       # tail -f the log
make status     # shuttle-ctl ps + snapshot summary
make clean      # rm _build and stray Elixir.*.beam at project root
```

Default `MIX_ENV=dev` matches the localhost:4000 endpoint config in
`config/dev.exs`. The Phoenix endpoint binds 127.0.0.1:4000 only when
`server: true` is set there — don't propagate that to other envs.

If `mix escript.build` warns about "redefining module Shuttle.X" with the
"current version loaded from Elixir.Shuttle.X.beam" hint, run `make clean`
first — stray `.beam` files at the project root shadow the real ones. They
should never be committed.

## How dispatch works

- **Poller** (`lib/shuttle/poller.ex`) is the single GenServer that owns the
  tick. It walks each configured `felt_host`, parses each `*.md` file's
  frontmatter, and considers a fiber eligible iff `shuttle.enabled: true` AND
  `status in ["open", "active"]` AND not already running/claimed AND deps
  satisfied.
- **No tag predicate.** `constitution` is a human convention only — a fiber
  with a `shuttle:` block dispatches with or without it. (Pre-`23e7b31` the
  daemon pre-filtered discovery on `-t constitution`; that's gone.)
- **Configured hosts** come from `LOOM_HOMES` (comma-separated) →
  `LOOM_HOME` → default `~/loom`. Earlier-configured hosts win on fiber-id
  collisions across hosts.
- **Dispatcher** (`lib/shuttle/dispatcher.ex`) resolves the agent from
  `shuttle.agent` against `share/agents.json`, spawns `shuttle-<fiber-id>`
  tmux session.
- **Standing roles** are recurring fibers — `shuttle.kind: standing` with a
  cron `schedule:`. Daemon dispatches only when `next_due_at` is due AND
  `review.state` is `scheduled` or `accepted`. Worker exit flips state to
  `awaiting`; `shuttle-ctl accept` advances `next_due_at`.

## Inspecting state

```
make status                              # daemon-side view
shuttle-ctl status                       # Go walker view (independent of daemon)
shuttle-ctl status -j                    # JSON
bin/shuttle snapshot                     # raw JSON snapshot
~/Library/Logs/shuttle.log               # daemon stdout/stderr
tmux ls | grep '^shuttle-'               # live workers
```

A useful sanity ladder when something isn't dispatching:

1. `shuttle-ctl status` shows `enabled: true, idle, oneshot`? → fiber is
   well-formed and the Go walker sees it.
2. `bin/shuttle snapshot` lists it under `eligible[]` with `state: running`?
   → daemon dispatched it.
3. If shuttle-ctl sees it but daemon doesn't → daemon binary is stale. `make
   restart`.
4. If daemon sees it but agent never appears → check `share/agents.json` for
   the resolved agent's `cli` and that the wrapper is on `PATH`.
5. If the snapshot has no `felt_hosts:` field → binary pre-`297a24d`. Same
   fix: `make restart`.

## Codebase layout

- `lib/shuttle/poller.ex` — GenServer; discover + eligibility + retry queue.
- `lib/shuttle/dispatcher.ex` — agent resolution, tmux launch, session-UUID
  capture for resume-previous.
- `lib/shuttle/agents.ex` — agent registry loaded from `share/agents.json`.
- `lib/shuttle_web/controllers/*` — agent-API HTTP endpoints (`/api/v1/...`).
- `cmd/shuttle/` — Go CLI (`shuttle-ctl`). Walks `<host>/.felt/` independently
  of the daemon — it's the human's view, not a dispatch dependency.
- `share/agents.json` — agent registry (claude-{sonnet,opus,haiku},
  codex, codex-mini, etc.).
- `config/dev.exs` — endpoint binding (the only env where `server: true`).

## Tests

```
mix test                   # full Elixir suite
mix test --only focus      # tagged subset
```

Disk-walking tests use real fixture directories under `test/support/` rather
than mocks — the walker is a thin filesystem read so this is faster and
catches more.

## Fibers for depth

- `ai-futures/shuttle/` (in `~/loom/.felt/`) — root, design fibers, all the
  shipped/in-flight constitutions (cutover, multi-host, CLI, daemon-shuttle-
  block-discovery, etc.).
- Postmortems live alongside as siblings (e.g. `postmortem-2026-05-03-icloud-
  loss`).
