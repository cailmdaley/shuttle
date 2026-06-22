# Shuttle

A felt-based take on [Symphony](https://github.com/openai/symphony), built for personal scale.

Shuttle polls your [felt](https://github.com/LightconeResearch/felt) fiber tree, launches one worker per eligible constitution in a named tmux session, and keeps a snapshot surface for dashboards and other consumers.

**Status:** in daily production use (Stages 0–6 complete). Stage 7 (BEAM distribution / multi-host SSH) is the next major milestone; see [Remote dispatch](#remote-dispatch).

## Principles

These motivated Shuttle and distinguish it from Symphony.

**Build to understand.** The author wanted to take Symphony apart and learn it by reimplementing it — different language, different integration layer. Symphony's spec-and-reference-impl pattern explicitly invites this kind of derivative work. The lineage is a feature, not a footnote.

**tmux is the surface.** Every worker is `tmux attach -t shuttle-<fiber-id>` away — for the human, the supervisor, and other agents. No web UI, no IDE bindings. This is the load-bearing reason the engine looks the way it does.

**Personal scale, not frontier-lab scale.** Symphony manages teams of agents on shared work; Shuttle helps one person navigate their own. The implications are concrete: no auth model, no team conventions, no review board — just `~/loom/.felt/`, the local daemon, and the person at the keyboard.

**Built on felt** for three properties:
- **Dependencies.** Constitutions can `depends_on:` other tempered fibers; Shuttle gates dispatch on that. Work composes the way thinking composes.
- **Plain markdown readability.** Fibers and constitutions are files a human can read in an editor, with `cat`, with `less`. No database, no JSON envelope. The data layer survives Shuttle.
- **Smooth human↔agent transition.** The same artifact a worker reads is the artifact the human edits. No translation layer, no separate "agent format."

## Lineage

Symphony (`openai/symphony`) ships a SPEC + reference implementation. Shuttle follows the same pattern:

- **Lifted from Symphony:** the coordination layer — poll/retry/reconcile state machine, OTP supervisor tree, Phoenix Channels broadcast idioms, failure-mode taxonomy.
- **Replaced for Shuttle:** the integration layer — Linear adapter → felt CLI; codex-app-server → tmux + agent CLI wrappers; `WORKFLOW.md` → fiber-frontmatter `shuttle:` block as constitution metadata.
- **Critical invariant carried over:** tmux owns the worker process; Shuttle owns the watcher (supervise watchers, not workers).

See `NOTICE` for full attribution.

## Three Artifacts

| Artifact | Language | Purpose |
|---|---|---|
| `bin/shuttle` | Elixir (OTP escript) | Daemon: polls fiber tree, dispatches workers, exposes HTTP snapshot |
| `felt shuttle` | (felt) | Agent-facing CLI: schema-validating fiber lifecycle verbs; works offline |
| Claude Code skill | YAML/Markdown | Worker protocol: how agents survey, work, and hand off |

Only the Elixir daemon lives in this repo. The agent-facing CLI is `felt shuttle <verb>` — felt absorbed every lifecycle verb, so there is nothing to build here for it. The Claude Code skill ships separately as a plugin — see [Skills](#skills).

## Requirements

- Erlang/OTP 26+ and Elixir 1.16+
- [felt](https://github.com/LightconeResearch/felt) CLI on `PATH` (also provides the `felt shuttle` agent-facing CLI)
- tmux

Shuttle depends on felt entirely through the felt CLI — no in-process parsing, no library import. `felt ls --json`, `felt show -j`, and `felt edit` are the seams. (Continuation state — `session_uuid` / `dispatched_at` / `handed_off_at` — rides in the fiber's `shuttle:` frontmatter block, written surgically; there is no separate history store.)

## Installation

One command stands up the full local surface — daemon, served UI, the loom event-stream hook, and a keep-alive supervisor — branching by host type (a launchd LaunchAgent on macOS, a `shuttle-daemon` respawn loop on the clusters):

```bash
git clone https://github.com/cailmdaley/shuttle
cd shuttle
./install.sh --dry-run   # check prerequisites + print the plan, change nothing
./install.sh             # full bootstrap for this host
```

The installer names any missing prerequisites and how to get them. Flags: `--skip-ui` / `--build-ui` (the UI bundle builds on macOS and is rsync'd to the clusters), `--skip-hook`, `--with-tunnels`.

Just the daemon, no supervisor:

```bash
mix deps.get && make build   # → bin/shuttle
```

The agent-facing CLI is `felt shuttle <verb>`, provided by the felt binary on your `PATH` — nothing to build here.

### Configure a felt store

Shuttle defaults to `LOOM_HOME` or `~/loom` as the felt store. Override with:

```bash
# Environment variable (takes precedence, comma-separated for multiple stores):
export LOOM_HOMES=~/loom,~/other-project

# Persistent registration (written through the HTTP API, survives restarts):
# POST /api/v1/felt-stores with {"felt_stores": ["/absolute/path/to/store"]}
```

## Running

```bash
# Start the daemon (detached; logs to ~/Library/Logs/shuttle.log on macOS)
make start

# Or use the escript directly:
bin/shuttle start

# Check what's running:
felt shuttle status      # all fibers with shuttle: blocks
felt shuttle ps          # live tmux workers only
bin/shuttle snapshot    # daemon's JSON view of eligible + running + standing
```

## Constitution Fibers

A constitution is a fiber with a `shuttle:` frontmatter block:

```yaml
---
name: My task
status: active
outcome: |-
  Current state visible on the kanban card.
tags:
  - constitution
shuttle:
  enabled: true
  kind: oneshot
  host: local
  project_dir: /path/to/project
  agent: claude-sonnet
---

# My Task

Describe desired state here. Shuttle dispatches a worker; the worker reads
this file, does the work, updates outcome:, and exits.
```

Install via `felt shuttle install <fiber-id> --project-dir "$PWD"` or write the block directly.

## Lifecycle Verbs

```bash
felt shuttle install  <fiber> --project-dir "$PWD" [-m <agent>] [--disabled]  # oneshot
felt shuttle repeat   <fiber> --schedule "0 9 * * 1-5" --tz Europe/Paris --project-dir "$PWD"
felt shuttle pause    <fiber>      # enabled=false → drafts; kills live worker unless --no-kill
felt shuttle resume   <fiber>      # enabled=true → in-flight
felt shuttle accept   <fiber>      # standing: advance next_due_at after review
felt shuttle close    <fiber>      # mark done; optionally --tempered true|false
felt shuttle reopen   <fiber>      # requeue a closed fiber
felt shuttle abort    <fiber>      # kill the worker's tmux session
felt shuttle attach   <fiber>      # tmux attach to a live worker
felt shuttle set-model <fiber> <agent-id>  # change agent
felt shuttle uninstall <fiber>     # remove shuttle: block
```

All write verbs validate the block before touching any file. The daemon picks up changes on its next poll.

## Standing Roles

A standing role is a recurring responsibility — a constitution with a cron schedule. Shuttle dispatches scheduled runs only when `next_due_at` is due and `review.state` is `scheduled` or `accepted`:

```yaml
shuttle:
  enabled: true
  kind: standing
  host: local
  project_dir: /path/to/project
  agent: claude-sonnet
  schedule:
    expr: "0 9 * * 1-5"
    tz: Europe/Paris
  review:
    state: scheduled
  next_due_at: "2026-05-05T09:00:00+02:00"
  last_run_at: null
```

The worker exits with `review.state: awaiting`; `felt shuttle accept <fiber>` advances `next_due_at` to the next occurrence. Manual standing-role dispatch uses an `adhoc-...` run id and preserves the existing `next_due_at` through accept, so an extra run does not consume the next scheduled slot.

## Agent Registry

Agents are owned by felt — the single source of truth for the merge. The Elixir daemon reads the already-resolved record off felt's `shuttle.resolved.agent` and shells `felt shuttle agents [resolve]` for the registry / no-fiber cases.

Built-in agents: `claude-sonnet`, `claude-opus`, `codex`, `codex-spark`, and several `pi-*` variants (for [pi](https://github.com/mariozechner/pi)). Add your own by following the same shape.

## Remote Dispatch

Stage 7 (BEAM distribution / SSH-tunnel multi-host) is in progress. The `--all` and `--remote` flags on `felt shuttle status` already pull composite snapshots from configured remote daemons via the local daemon's `/api/v1/state/composite` endpoint. Multi-host dispatch (fibers eligible on one machine dispatched to another) is the next step.

## Skills

The Claude Code skill ships as a separate plugin. It documents the worker protocol: how agents survey the constitution, carry the work forward, rewrite the `## Status` handoff block, and exit cleanly via `felt shuttle handoff` (which stamps `shuttle.handed_off_at` and ends the worker's own tmux session). Install it as a Claude Code extension to make it available in worker sessions.

A `Shuttle.WorkSource` behaviour (for non-felt adapters like Linear) is planned but out of scope for v0; follow the tracking issue for progress.

## Build Reference

```bash
make build    # mix escript.build → bin/shuttle
make start    # start daemon detached
make stop     # SIGTERM with 5s grace
make restart  # build + stop + start (the load-bearing daemon target)
make all      # restart (daemon)
make logs     # tail -f the daemon log
make status   # felt shuttle ps + snapshot summary
make clean    # rm _build and stray .beam files

mix test                    # Elixir suite

# Opt-in real harness smoke: opens Claude/Codex/Pi in tmux, sends no prompt,
# captures the idle pane, then kills the smoke-owned sessions.
SHUTTLE_REAL_HARNESS_SMOKE=1 mix test --only integration test/shuttle/real_harness_smoke_test.exs
```

## License

Apache 2.0 — see `LICENSE`. Symphony attribution in `NOTICE`.
