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
| `shuttle-ctl` | Go | Agent-facing CLI: schema-validating fiber lifecycle verbs; works offline |
| Claude Code skill | YAML/Markdown | Worker protocol: how agents survey, work, and hand off |

The Elixir daemon and Go CLI are in this repo. The Claude Code skill ships separately as a plugin — see [Skills](#skills).

## Requirements

- Erlang/OTP 26+ and Elixir 1.16+
- Go 1.21+
- [felt](https://github.com/LightconeResearch/felt) CLI on `PATH`
- tmux

Shuttle depends on felt entirely through the felt CLI — no in-process parsing, no library import. `felt ls --json`, `felt show -j`, `felt edit`, and `felt history append` are the seams.

## Installation

```bash
git clone https://github.com/cailmdaley/shuttle
cd shuttle

# Build the daemon
mix deps.get && mix escript.build
# bin/shuttle is now built

# Build the CLI and install to ~/go/bin/shuttle-ctl
make cli
```

Add `~/go/bin` (or wherever `$(GOPATH)/bin` points) to your `PATH` so `shuttle-ctl` is available.

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
shuttle-ctl status      # all fibers with shuttle: blocks
shuttle-ctl ps          # live tmux workers only
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

Install via `shuttle-ctl install <fiber-id> --project-dir "$PWD"` or write the block directly.

## Lifecycle Verbs

```bash
shuttle-ctl install  <fiber> --project-dir "$PWD" [-m <agent>] [--disabled]  # oneshot
shuttle-ctl repeat   <fiber> --schedule "0 9 * * 1-5" --tz Europe/Paris --project-dir "$PWD"
shuttle-ctl pause    <fiber>      # enabled=false → drafts; kills live worker unless --no-kill
shuttle-ctl resume   <fiber>      # enabled=true → in-flight
shuttle-ctl accept   <fiber>      # standing: advance next_due_at after review
shuttle-ctl close    <fiber>      # mark done; optionally --tempered true|false
shuttle-ctl reopen   <fiber>      # requeue a closed fiber
shuttle-ctl abort    <fiber>      # kill the worker's tmux session
shuttle-ctl attach   <fiber>      # tmux attach to a live worker
shuttle-ctl set-model <fiber> <agent-id>  # change agent
shuttle-ctl uninstall <fiber>     # remove shuttle: block
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

The worker exits with `review.state: awaiting`; `shuttle-ctl accept <fiber>` advances `next_due_at` to the next occurrence. Manual standing-role dispatch uses an `adhoc-...` run id and preserves the existing `next_due_at` through accept, so an extra run does not consume the next scheduled slot.

## Agent Registry

Agents live in `share/agents.json` — the single source of truth for both the Elixir daemon and the Go CLI (embedded at compile time). Edit the JSON, then `make restart` to pick up changes.

Built-in agents: `claude-sonnet`, `claude-opus`, `codex`, `codex-spark`, and several `pi-*` variants (for [pi](https://github.com/mariozechner/pi)). Add your own by following the same shape.

## Remote Dispatch

Stage 7 (BEAM distribution / SSH-tunnel multi-host) is in progress. The `--all` and `--remote` flags on `shuttle-ctl status` already pull composite snapshots from configured remote daemons via the local daemon's `/api/v1/state/composite` endpoint. Multi-host dispatch (fibers eligible on one machine dispatched to another) is the next step.

## Skills

The Claude Code skill ships as a separate plugin. It documents the worker protocol: how agents survey the constitution, carry the work forward, write the editorial handoff, and exit cleanly. Install it as a Claude Code extension to make it available in worker sessions.

A `Shuttle.WorkSource` behaviour (for non-felt adapters like Linear) is planned but out of scope for v0; follow the tracking issue for progress.

## Build Reference

```bash
make build    # mix escript.build → bin/shuttle
make start    # start daemon detached
make stop     # SIGTERM with 5s grace
make restart  # build + stop + start (the load-bearing daemon target)
make cli      # go build → ~/go/bin/shuttle-ctl
make all      # restart + cli
make logs     # tail -f the daemon log
make status   # shuttle-ctl ps + snapshot summary
make clean    # rm _build and stray .beam files

mix test                    # Elixir suite (110 tests)
go test ./pkg/schema/...    # Go schema tests
```

## License

Apache 2.0 — see `LICENSE`. Symphony attribution in `NOTICE`.
