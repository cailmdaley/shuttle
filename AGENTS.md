# Shuttle — Contributor Notes

Local OTP-supervised dispatcher for felt constitution workers. Polls the felt
tree, launches one tmux worker per eligible fiber, exposes a snapshot surface
for dashboards and other consumers.

The Elixir daemon is the production dispatcher.

## Direction — standalone, then merged with felt

**Shuttle is becoming a fully independent package.** Portolan is being retired;
treat Shuttle as a self-contained tool with its own browser UI, its own launch
story, and no assumption that any Portolan process is running. When you touch
code that reaches for Portolan — its `:4004` backend, its hook-event stream, its
city/pinning model, its origins — the goal is to sever, not to preserve parity.
Portolan is a peer that happened to come first, not a dependency. Default to not
referencing it at all; the historical comments that explain *why* a shape exists
("ported from Portolan's …") are fine to leave as provenance, but new code and
new docs should stand on their own.

**Long-term: Shuttle and felt merge into one compact, cohesive package.** The
end state is a single tool — the felt tree as the data layer and Shuttle's
dispatch + UI as the surface over it — simplified down from the current
daemon/CLI/UI spread. When weighing a change, prefer the design that moves
toward that convergence: fewer moving parts, fewer cross-process contracts, felt
and Shuttle as one thing rather than two that shell to each other.

### Where Shuttle still depends on / references Portolan

Live runtime couplings (these silently break or no-op without Portolan, and are
the real severing work):

- **`lib/shuttle/waiting_tracker.ex`** (and `sent_files.ex`, which delegates to
  its `default_events_file/0`) — read the Claude Code hook-event stream to derive
  per-session activity / "waiting" phase and the sent-files trail. **Shuttle now
  owns its own stream:** the readers prefer the Shuttle-owned path
  (`SHUTTLE_EVENTS_FILE`, else `$SHUTTLE_DATA_DIR/events.jsonl`, default
  `~/.shuttle/events.jsonl`, written by `~/loom/hooks/shuttle-hook.sh`) and **fall back**
  to the legacy Portolan path (`PORTOLAN_EVENTS_FILE` /
  `~/.portolan/data/events.jsonl`, written by `~/loom/hooks/portolan-hook.sh`)
  only when the Shuttle file is absent or empty. So behavior is unchanged until
  the Shuttle hook is installed (see "Owning the event stream" below), then it
  transparently switches. The event shape is identical, so the parsers are
  unchanged. Fully severing means dropping the Portolan fallback once the hook is
  installed everywhere.
- **UI `:4004` backend (`ui/src/board/FiberDetailModal.ts`, `FileViewerPanel.ts`)** —
  `portolanBase` defaults to `http://localhost:4004` and the standalone
  `KanbanModal` never overrides it, so **Sent-files**, **Save-to-downloads**, and
  the **project-file viewer** all hit a Portolan backend that won't exist once
  it's retired. These features are dead in the standalone UI today. Severing
  means serving those routes from the `:4000` daemon (or dropping them).
- **`lib/shuttle_web/cors_plug.ex`** — allowlists Portolan.app's Tauri
  custom-protocol origins. Harmless but dead once Portolan is gone; trim.
- **UI fonts (`ui/src/board/KanbanModal.css`)** — references fonts "served from
  Portolan's `public/fonts/`". Vendor them into `ui/` instead.

Conceptual/data-model coupling (no runtime dependency, but the design carries
Portolan assumptions worth unwinding as Shuttle simplifies):

- **City / pinning model** (`KanbanCityResolver.ts`, `projectModel.ts`,
  `KanbanReadModel.ts`) — "which city owns this fiber" is a Portolan-local
  concept the daemon feed doesn't carry; the UI reconstructs it from loom paths.
- **`kind` / `priority` / `isRoot`** (`KanbanFiber.ts`) — "Portolan conventions
  felt does not interpret," defaulted client-side.
- **Gate/transition semantics** (`transition.ex`, `origins_controller.ex`,
  `actions.ex`) — mirror Portolan's kanban placement pipeline.

The remaining `grep -ri portolan` hits are historical provenance comments — no
action needed beyond letting them age out as the code they describe is rewritten.

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

make install-agent    # durable launchd keep-alive (crash + login restart)
make uninstall-agent  # unload + remove the launchd agent
```

### Durable launch (macOS) — `make install-agent`

`make start` is a bare `nohup` with no supervisor: it won't restart on crash or
relaunch at login. Shuttle's own durable surface is a **launchd LaunchAgent**
(`share/io.shuttle.daemon.plist.template` → `~/Library/LaunchAgents/io.shuttle.daemon.plist`),
installed by `make install-agent`: `KeepAlive` restarts the daemon on crash,
`RunAtLoad` starts it at login. Independent of any other process.

**Run it from outside `~/Documents` — this is load-bearing.** macOS TCC blocks
launchd-spawned processes from `~/Documents`, `~/Desktop`, and `~/Downloads`, and
**Full Disk Access does not inherit** the way it does under Terminal (a terminal
app *takes responsibility* for its children, so everything you launch from a
shell shares the terminal's grant; launchd has no such umbrella, and FDA doesn't
even cross an `exec` to a differently-signed binary). So a launchd daemon whose
escript/`ui/dist`/felt stores sit under `~/Documents` either crash-loops
(`getcwd: Operation not permitted`, `escript: Failed to open file`) or silently
fails to walk stores — and the fix would be granting FDA to *each* binary in the
tree (`beam.smp`, `felt`, …), which is fragile (the erlang path is
version-pinned) and exactly the per-binary grind to avoid.

The clean setup, and the current production layout:

- **The repo lives outside Documents** — the canonical checkout is
  **`~/dev/shuttle`** (not `~/Documents/projects/shuttle`). The escript and
  `ui/dist` are then readable by launchd with no grant.
- **`AGENT_LOOM_HOMES` scopes felt polling to `~/loom`** (the Makefile default,
  baked into the plist as `LOOM_HOMES`). `~/loom` is outside Documents and the
  felt aggregate — it re-discovers each project's substores by following the
  symlinks under `~/loom/.felt/` (`FeltStores.expand_with_symlinked_substores`),
  so configuring just `~/loom` is enough. **Caveat:** substores whose real root
  is itself under a protected folder (e.g. an iCloud `wedding`, a Documents
  `lightcone`) are discovered but can't be walked by the launchd daemon — those
  fibers won't enumerate until their project roots also move out of Documents.
- **`PATH` is captured from a login shell at install time** (`AGENT_PATH` in the
  Makefile, baked into the plist). launchd's own env is too bare to find
  `escript` (Homebrew) at boot or `felt` (`~/.local/bin`) at runtime — and a
  login shell *at runtime* (`bash -lc`) does NOT fix it, because under launchd's
  bare env the profile doesn't reconstruct PATH (exit 127, escript unfound). A
  PATH missing `felt` specifically yields `:enoent` → **500 on
  `/api/v1/fibers/composite`** (the kanban load), with the board fine otherwise.
  Capturing the real login PATH once, at install, is deterministic and needs no
  hand-maintained list.

Result: `make install-agent` from `~/dev/shuttle` → daemon binds `:4000`,
KeepAlive + RunAtLoad, **zero Full Disk Access grants**, survives erlang
upgrades. On the clusters the durable surface is still the `while true;
bin/shuttle start` tmux respawn loop in session `shuttle-daemon` (no launchd);
the LaunchAgent is macOS-only.

`make install-agent` warns if `$PWD` is under a protected folder. There *is* an
escape hatch — granting FDA to each I/O binary in the tree (`…/erlang/<v>/…/beam.smp`,
re-granted after every erlang upgrade, plus `~/.local/bin/felt`) — but it's
fragile and per-binary; relocating out of Documents is the supported fix.

### Owning the event stream — `~/loom/hooks/shuttle-hook.sh`

Shuttle derives per-session activity (`WaitingTracker`) and the sent-files trail
(`SentFiles`) from a Claude Code hook-event stream. `~/loom/hooks/shuttle-hook.sh`
appends one JSON line per hook event to `$SHUTTLE_EVENTS_FILE` (default
`~/.shuttle/events.jsonl`, dir `$SHUTTLE_DATA_DIR`), in the same shape the legacy
`portolan-hook.sh` writes, so the daemon no longer depends on Portolan's hook.
Until the hook is registered on a machine, the readers fall back to Portolan's
`~/.portolan/data/events.jsonl` there, so nothing breaks in the meantime.

**The hook lives in loom, registered by `loom/setup.sh` — exactly like
portolan-hook.** The reason it can't live in this repo: `~/loom` is the same
absolute path on every machine, but the shuttle checkout is not (`~/dev/shuttle`
here, `~/Documents/projects/shuttle` on the clusters), and `~/.claude/settings.json`
needs a stable absolute `command` path. `loom/setup.sh`'s Python block registers
`~/loom/hooks/shuttle-hook.sh` into `~/.claude/settings.json` across the tracked
events (UserPromptSubmit, PreToolUse, Stop, Notification, SessionStart, SessionEnd),
*alongside* portolan-hook for now (both fire, write their own files; drop the
portolan entries once Portolan is fully retired). To install on a machine: sync
loom there, then run `~/loom/setup.sh`. The hook needs `jq` on PATH; without it it
exits silently and the readers keep using the Portolan fallback. Each host's
daemon tails its own host's `~/.shuttle/events.jsonl`.

**Connecting to candide and cineca (SSH auth — read this first).** The two
remotes authenticate differently, and getting it wrong looks like "the host is
down" when it isn't:

- **candide** (`candid03.iap.fr`, IAP) — plain pubkey auth with `~/.ssh/id_rsa`
  (the `Host *` identity), reached through an `nc` `ProxyCommand` hop. No cert
  dance: `ssh candide` just works whenever you're on a network that can reach
  IAP. Nothing expires.
- **cineca** (`login07-ext.leonardo.cineca.it`, user `cdaley00`, Leonardo) —
  auth is a **step-ca short-lived SSH certificate** held in the ssh-agent,
  valid **24h**. Refresh it once per day with:

  ```bash
  step ssh login 'cail.daley@cea.fr' --provisioner cineca-hpc
  ```

  When the cert is fresh, `ssh cineca` works non-interactively. When it has
  expired, **every** `ssh cineca` fails instantly with `Permission denied` —
  including the kanban **Attach** button, which runs `ssh -tt cineca tmux attach
  …` in a kitty tab, so the symptom is a terminal that **flashes open and dies**.
  That is the expired cert, not a Shuttle bug: re-run the `step ssh login` and
  attach works again. The `~/.ssh/cineca_key` / `cineca_key-cert.pub` paths in
  the ssh config are step's cert store — they may be absent on disk and ssh
  prints a harmless `no such identity` warning; the live credential is the cert
  in the agent. **Do not** pass `-o BatchMode=yes` when sanity-checking cineca
  (it suppresses the cert path and falsely reports a dead host), and ignore
  `~/.ssh/ssh_wrapper.sh` entirely — it's VS Code's remote helper, unrelated to
  Shuttle.

**Deploying is ALWAYS safe — local or remote — and is never a blocker.**
Rebuilding and restarting the daemon (`make all`, cycling `:4000`, reloading the
LaunchAgent, the respawn loop) does **not** kill running jobs: **tmux owns the
worker process, Shuttle only owns the watcher** (the load-bearing invariant
below). A restart cycles the watcher and rebinds the API; the `shuttle-<id>`
tmux sessions keep running untouched and the daemon re-adopts them on boot. So
deploy freely whenever there's a fix to ship — never hold back, gate it behind
"there are workers running," or frame a deploy as risky. The only cost is the
brief API/board blip during the ~1s (local) to ~2min (candide cold-walk)
restart; in-flight work is unaffected.

**Deploying to remote hosts (candide, cineca):** push to GitHub first, then build on the host — don't copy the macOS escript, as BEAM bytecode format varies across OTP versions and the binary will crash on startup on a different host.

```bash
ssh candide "cd ~/Documents/projects/shuttle && git pull && make all"
ssh cineca  "cd ~/Documents/projects/shuttle && git pull && make all"
```

After a remote deploy, verify both `/api/v1/version` and one behavior-shaped
payload. A new `git_short_sha` only proves `BuildInfo` was rebuilt; if the live
payload still has old semantics, run `make clean && make build`, then let the
respawn loop restart the daemon from the clean escript.

**The respawn loop owns the remote daemon — `make stop`/`make all` may not
cycle it.** On candide/cineca a `while true; ./bin/shuttle start` loop in tmux
session `shuttle-daemon` owns the live daemon. `make stop`/`make all` target the
pidfile that `make start` writes, which is *not* the respawn-spawned daemon, so
they can build a fresh `bin/shuttle` yet leave the old binary serving `:4000`. To
actually cycle to the new binary, **kill the `:4000` listener directly**
(`lsof -ti:4000 -sTCP:LISTEN | xargs kill`) — the respawn loop restarts it from
the rebuilt escript. Confirm `git_short_sha` flipped; if not, the old process is
still bound. **candide startup is slow (~2 min)** — it scans large shapepipe felt
stores and adopts orphan sessions before binding `:4000`; wait it out, don't
assume a crash.

Candide: OTP 27.3.4.12 pinned in `~/.tool-versions`. Daemon log:
`~/.shuttle/shuttle.log`. cineca runs OTP 28.0.2 and **compiles fine** (the old
"OTP 28.0.x compilation crash" no longer reproduces on current `main`; only a
non-fatal "regexes re-compiled at runtime" perf warning remains — OTP 28.1+ or
27- silences it).

**The daemon serves its own web UI at `http://127.0.0.1:4000/`** — the kanban
board, Stash/Capture, and the fiber/file viewer, served as the static `ui/dist`
bundle by the same process as the `:4000` API (`Plug.Static` + `SpaController`).
To pull it up locally: `make start` (or Portolan's `dev.sh`), then open the root
URL in a browser. A fresh checkout that hasn't built the bundle gets a 404 with
the hint `cd ui && npm run build`; the API stays usable regardless.

**The UI bundle is shipped, not built on-host.** `make all` rebuilds only the
Elixir escript — it does *not* build `ui/dist`. And the UI **can't** be built on
the clusters from a source-only `lightcone-ui` clone: the aliased renderer source
imports its myst peers (`myst-to-react`, `@myst-theme/*`), which Node resolves
from `lightcone-ui`'s *own* `node_modules` — present only after a `pnpm install`
of that workspace. But the bundle is host-independent static output, so the lean
path is **build `ui/dist` locally (where the deps resolve) and `rsync` it**:

```bash
cd ui && npm run build              # locally; lightcone-ui present → paper entry included
rsync -az --delete ui/dist/ candide:~/Documents/projects/shuttle/ui/dist/
rsync -az --delete ui/dist/ cineca:~/Documents/projects/shuttle/ui/dist/
```

(The renderer is compiled *into* the bundle, so a remote serving the shipped
`dist` self-serves the paper render — it needs no `lightcone-ui` at runtime.)

**The ASTRA paper path needs node + a built MySTRA on each owning host.**
`GET /api/v1/astra` is owner-routed and shells out to `priv/mystra/bake.mjs`,
which imports MySTRA's built `dist`. Each host that *owns* astra.yamls you want
to render needs: `node` (any v22+) and a MySTRA checkout built once —
`git clone -b cail/migrate-to-astra-spec-sdk …/MySTRA && cd MySTRA && npm install
&& npm run build` at `~/Documents/projects/LightconeResearch/MySTRA` (the sibling
path `bake.mjs` resolves by default; its `dist/` is gitignored). The bake finds
node via a `bash -lc` login-shell fallback, so it works even though the respawn
loop sources asdf but not nvm. A host without node/MySTRA fails `/astra` cleanly;
the board + fibers are unaffected.

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
shuttle-ctl validate-identity                # UID migration/cross-city validation
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
- **`shuttle.host` field drives daemon affinity — strictly.** A daemon
  dispatches a block iff `block.host == own_host_id` (its `SHUTTLE_HOST` or
  `:inet.gethostname()`). There is no `"local"` default and no `nil`
  wildcard: an absent or empty `host:` is unowned and ineligible on *every*
  daemon. `shuttle-ctl install`/`repeat` stamp `host` by default so blocks
  are born owned. The same predicate gates the orphan-resurrection path, so
  a remote restart can't re-grab another host's fiber.
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
  configured felt store, pulls candidate metadata via `felt ls --json` and
  per-fiber detail via `felt show -j`, and considers a fiber eligible iff
  `shuttle.enabled: true` AND `status in ["open", "active"]` AND not
  already running AND deps satisfied.
- **Configured stores** come from `LOOM_HOMES` (comma-separated env var) →
  persisted `~/.shuttle/felt_stores.json` → `LOOM_HOME` → `~/loom`.
  `POST /api/v1/felt-stores` rewrites the persisted file.
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
3. **`Felt store: <path>`** — the worker's absolute anchor. When
   `prompt_fiber_id`'s work_dir-local translation safe-fails, the id above
   is global and doesn't resolve from cwd; the store line makes the
   fallback mechanical (`felt -C <felt-store> show <id>`).
4. **`From User · <relative time>`** — the most recent `--kind
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
shuttle-ctl validate-identity                # checks :4000/:4001/:4002 by default
```

Dispatch sanity ladder:

1. `shuttle-ctl status` shows `enabled: true, idle, oneshot`? → fiber is
   well-formed and the Go walker sees it.
2. `bin/shuttle snapshot` lists it under `eligible[]`? → daemon dispatched.
3. shuttle-ctl sees it but daemon doesn't → daemon binary is stale.
   `make restart`.
4. Daemon sees it but agent never appears → check `share/agents.json` for
   the resolved agent's `cli` and that the wrapper is on `PATH`.

**Kanban stuck on "Loading…" / `/api/v1/state` returns
`{"error":"poller_unavailable", ..., "{:timeout, {GenServer, :call, [Shuttle.Poller, …, 1500]}}"}`
right after a fresh daemon start.** The poller serves its *last* snapshot, but on
a cold boot there is none yet, so the snapshot call starves behind the first full
walk until it completes — and the **first tick on a fresh machine is cold**: empty
OS file cache, dataless iCloud sidecars (`com~apple~CloudDocs` stores ship `.felt`
index files as `dataless` placeholders that block on a network download the first
time `felt` reads them), and every configured store walked back-to-back. Observed
once at **~106s** (`Sent 200 in 106275ms` in `shuttle.log`). It is a one-time tax:
once warm, all stores poll in well under a second and the board loads. So **wait
out the first walk** rather than trimming `~/.shuttle/felt_stores.json` — the
persisted list is fine, and most project stores are slices of `~/loom` (the
aggregate store; its ids are already prefixed `ai-futures/…`, `portolan/…`) so
trimming gains little. Two real follow-ups: (1) a store path with **no `.felt/`
dir** ("not in a felt repository") errors every tick — drop it from the list;
(2) the remotes timing out independently (`ssh_check_failed`, `:4001
econnrefused`) is separate noise, not this.

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

# Opt-in real harness smoke. Opens real Claude/Codex/Pi CLIs in tmux,
# sends no prompt, captures the idle pane, then kills the smoke sessions.
SHUTTLE_REAL_HARNESS_SMOKE=1 mix test --only integration test/shuttle/real_harness_smoke_test.exs
```

The real harness smoke is deliberately outside ordinary `mix test`. It uses
tmux session names like `shuttle-harness-smoke-<harness>-<unique>`, records
captures under `_build/test/shuttle_harness_smoke/`, and skips harnesses that
are not available in `bash -l`.

## Contributing

See `CONTRIBUTING.md`.
