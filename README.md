# Shuttle

Shuttle is a local OTP-supervised dispatcher for felt constitution workers. It
polls the felt tree, launches one worker per eligible constitution in tmux, and
keeps a snapshot surface for Portolan and other consumers.

## Standing Roles

A standing role is a recurring responsibility represented by one durable fiber.
The role stays `status: active`, but `active` means installed rather than
immediately dispatchable. Shuttle reads the raw `shuttle:` frontmatter block and
dispatches a run only when `next_due_at` is due and `shuttle.review.state` is
scheduled or accepted:

```yaml
tags:
  - constitution
  - standing
  - agent:codex
shuttle:
  mode: standing
  schedule:
    kind: cron
    expr: "0 9 * * 1-5"
    timezone: Europe/Paris
  review:
    state: scheduled
    run_id: null
    accepted_run_id: null
  next_due_at: "2026-05-04T09:00:00+02:00"
  last_run_at: null
```

When a due role runs, Shuttle renders a standing-run prompt with a stable run id.
The worker writes the latest work product into `outcome:`, appends an editorial
history event, and manually edits the same fiber's `shuttle:` block into
awaiting review:

```yaml
shuttle:
  mode: standing
  review:
    state: awaiting
    run_id: "20260504T090000+0200"
    completed_at: "2026-05-04T09:12:00+02:00"
    accepted_run_id: null
  next_due_at: null
  last_run_at: "2026-05-04T09:12:00+02:00"
```

That clears `next_due_at`, so the role cannot hot-loop. After review, the user
or a later agent accepts the run by editing the same metadata and appending an
ordinary `felt history` event:

```yaml
shuttle:
  mode: standing
  review:
    state: accepted
    run_id: "20260504T090000+0200"
    accepted_run_id: "20260504T090000+0200"
    accepted_at: "2026-05-04T09:30:00+02:00"
  next_due_at: "2026-05-05T09:00:00+02:00"
  last_run_at: "2026-05-04T09:12:00+02:00"
```

Shuttle validates this state when it reads the fiber. In v0, typed
Shuttle-specific felt verbs are intentionally deferred; the durable source of
truth is the frontmatter plus felt history.

The v0 schedule evaluator supports interval schedules, daily schedules, and the
simple cron shape `M H * * DOW` used by the local canary.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `shuttle` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:shuttle, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/shuttle>.
