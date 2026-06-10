defmodule Shuttle.Dispatcher do
  @moduledoc """
  Dispatches a single worker for a felt constitution fiber.

  Reproduces the behavior of shuttle-worker.sh in Elixir:
  - Locates the fiber via felt CLI
  - Checks status (refuses closed)
  - Checks for existing tmux session
  - Creates tmux session with dispatch prompt
  - Invokes the resolved agent wrapper

  Stage 2: one-shot dispatch only. No poller, no watcher, no retry.
  """

  require Logger

  alias Shuttle.Agents
  import Bitwise

  @type dispatch_result ::
          {:ok, String.t()}
          | {:error, :not_found}
          | {:error, :closed}
          | {:error, :already_running}
          | {:error, :missing_session_id}
          | {:error, String.t()}

  @doc """
  Dispatches a worker for the given fiber ID.

  Returns `{:ok, tmux_session_name}` on success, or an error tuple.

  Options:
    * `:runner` — module implementing `Shuttle.Runner` behavior for test injection.
      Defaults to `Shuttle.Runner.Default`.
    * `:work_dir` — working directory for the tmux session. Defaults to `File.cwd!()`.
    * `:felt_store` — directory containing the `.felt/` index this dispatch
      should read fibers and history from. Defaults to `default_felt_store/0`.
      The Poller passes its configured `state.felt_store` here so each shuttle
      instance is consistent within itself; running multiple shuttle instances
      against different felt stores (e.g. one for `~/loom`, another for a
      standalone project root) is the supported way to span felt stores.
    * `:prompt_context` — `:constitution` (default) or `:standing_run`.
    * `:force_fresh` — when true, ignore any prior resume intent and start a
      new session. Used for autonomous continuation loops; explicit
      human-triggered "Resume previous" remains the only path that reuses a
      transcript.
    * `:force` — explicit manual dispatch override. When true, the dispatcher
      stops refusing closed fibers (the Poller already relaxes eligibility
      under force) and `resolve_resume_intent` ignores the ad-hoc
      short-circuit so the most recent review-comment's `resume_mode` is
      honored regardless of dispatch context.
    * `:runtime_session_id` — prior session UUID the caller already resolved (a
      live in-memory watcher record within the daemon's lifetime). Falls back to
      felt history (`latest_history_session_id`) when absent, which is the
      durable home post-slice-6 (no runtime store, no doc-resident session).
  """
  @spec dispatch(String.t(), keyword()) :: dispatch_result()
  def dispatch(fiber_id, opts \\ []) do
    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    work_dir = Keyword.get(opts, :work_dir, File.cwd!())
    prompt_context = Keyword.get(opts, :prompt_context, :constitution)
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())
    force = Keyword.get(opts, :force, false)

    with {:ok, fiber} <- fetch_fiber(fiber_id, runner, felt_store: felt_store),
         uid = Map.get(fiber, "uid"),
         :ok <- check_not_closed(fiber, force),
         :ok <- maybe_reopen_on_force(fiber_id, fiber, force, runner, felt_store),
         :ok <- check_not_running(fiber_id, uid, runner),
         {:ok, agent} <- resolve_agent(fiber),
         :ok <- validate_agent(agent) do
      # Human-worker no-op: when the fiber's agent is `human`, the user is
      # working on it themselves; Shuttle has nothing to dispatch. Return a
      # sentinel so the caller (Poller / DispatchController) can skip the
      # watcher / running-state plumbing without surfacing it as an error.
      if agent.id == "human" do
        Logger.info("Human-worker dispatch for #{fiber_id} — no tmux session spawned")
        {:ok, :human_no_op}
      else
        resume_intent =
          cond do
            Keyword.get(opts, :force_fresh, false) ->
              :fresh

            true ->
              resolve_resume_intent(prompt_context, fiber_id, fiber, felt_store,
                force: force,
                session_id: Keyword.get(opts, :runtime_session_id)
              )
          end

        case resume_intent do
          {:error, _} = error ->
            error

          resume_intent ->
            create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context, resume_intent,
              felt_store: felt_store,
              uid: uid
            )
        end
      end
    end
  end

  @doc """
  Decides whether this dispatch should resume a prior worker session or start
  fresh, based on the prompt context.

  - Ad-hoc standing-role dispatches default to fresh. Resuming would land
    the worker in a transcript whose last assistant turn was "Run accepted.
    Exiting" — they'd idle ("nothing new on the fiber") instead of doing the
    new run. The kanban modal's manual "Resume" button overrides this by
    passing `force: true`, which routes back through `check_resume_intent`
    so the freshly-filed review-comment's `resume_mode` is honored.
  - Scheduled standing-role dispatches scope the review-comment lookup to the
    current run window — events at or after the **last worker-exit event in
    felt history** (`run_window_start/3`). A stale `resume_mode: "previous"`
    from a prior run would otherwise gate every future scheduled dispatch with
    `:missing_session_id` (see `loom/email/morning-post` blocked for 5 days,
    2026-05-09 → 2026-05-14). The window start lives in felt history — the
    chronological substrate — not in a `review.run_id` the document no longer
    carries: a resume directive filed after the awaiting run exited
    necessarily post-dates that exit, so it falls inside the window.
  - All other contexts defer to `check_resume_intent/3`, which reads the
    most recent review-comment from felt history and honors its `resume_mode`.

  Options:
    * `:force` — when true, the ad-hoc short-circuit is skipped and the
      latest review-comment's intent wins. Set by manual kanban dispatches.
  """
  @spec resolve_resume_intent(any(), String.t(), map(), String.t() | nil, keyword()) ::
          :fresh | {:previous, String.t()} | {:error, :missing_session_id}
  def resolve_resume_intent(prompt_context, fiber_id, fiber, felt_store, opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    case prompt_context do
      {:standing_run, _, :ad_hoc} when not force? ->
        :fresh

      _ ->
        since =
          if force?, do: nil, else: run_window_start(prompt_context, fiber_id, felt_store)

        check_opts =
          [since: since]
          |> then(fn o -> if is_nil(felt_store), do: o, else: [{:felt_store, felt_store} | o] end)
          |> then(fn o ->
            case Keyword.get(opts, :session_id) do
              session_id when is_binary(session_id) and session_id != "" ->
                [{:session_id, session_id} | o]

              _ ->
                o
            end
          end)

        check_resume_intent(fiber_id, fiber, check_opts)
    end
  end

  # The lower bound for the review-comment lookup on a standing run: the
  # timestamp of the most recent worker-exit event in felt history. felt history
  # is the chronological substrate (slice 4 — the document no longer carries a
  # `review.run_id`), so the run window starts where the awaiting run ended. A
  # resume directive is filed AFTER the run exits, so it lands at or after this
  # bound and `check_resume_intent --since` finds it; a stale directive from an
  # older run (before the last exit) falls outside and can't silently gate the
  # dispatcher. Non-standing contexts (oneshots, ad-hoc) impose no window.
  defp run_window_start({:standing_run, _run_id}, fiber_id, felt_store),
    do: last_worker_exit_at(fiber_id, felt_store: felt_store)

  defp run_window_start({:standing_run, _run_id, _}, fiber_id, felt_store),
    do: last_worker_exit_at(fiber_id, felt_store: felt_store)

  defp run_window_start(_, _fiber_id, _felt_store), do: nil

  # The `occurred_at` of the latest worker-exit event in felt history, parsed to
  # a DateTime. Mirrors `latest_history_session_id` (same event, parsed for its
  # timestamp instead of its session id). nil when no exit event is recorded
  # (a never-run role) — then the lookup spans all of history.
  defp last_worker_exit_at(fiber_id, opts) do
    felt_store = Keyword.get(opts, :felt_store) || default_felt_store()

    fiber_id
    |> query_history(["--last", "20", "--json"], felt_store: felt_store)
    |> Enum.find_value(fn event ->
      text = get_in(event, ["payload", "text"])

      if is_binary(text) and String.contains?(text, "worker exited") do
        parse_occurred_at(Map.get(event, "occurred_at"))
      end
    end)
  end

  defp parse_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_occurred_at(_), do: nil

  @doc """
  Checks whether the most recent review-comment requests resume of the previous
  worker session and, if so, whether a stored session UUID is available.

  Returns one of:
  - `:fresh` — no resume requested, or a fresh run was explicitly requested.
  - `{:previous, session_id}` — resume requested and session UUID available.
    The dispatcher will invoke the harness-appropriate resume command.
  - `{:error, :missing_session_id}` — previous-session resume was requested,
    but neither the daemon runtime store, legacy `shuttle.session.id`, nor
    worker-exit history contains a usable session id. The caller should surface
    this instead of silently starting fresh; "New session" is the explicit fresh
    path.

  Reads the latest `--kind review-comment` event from felt history. The
  `resume_mode` field in the event payload is set at requeue time by the user
  clicking "Requeue fresh" or "Resume previous" in the Kanban UI.

  Options:
    * `:since` — `DateTime` lower bound passed through to `felt history
      --since`. Used by scheduled standing-run dispatches to ignore
      directives that pre-date the current run window. When unset (oneshots,
      ad-hoc dispatches), the latest review-comment of all time applies.
    * `:session_id` — daemon-owned prior session UUID supplied by the Poller.
  """
  @spec check_resume_intent(String.t(), map(), keyword()) ::
          :fresh | {:previous, String.t()} | {:error, :missing_session_id}
  def check_resume_intent(fiber_id, _fiber, opts \\ []) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    since_args =
      case Keyword.get(opts, :since) do
        %DateTime{} = dt -> ["--since", DateTime.to_iso8601(dt)]
        _ -> []
      end

    case query_history(
           fiber_id,
           ["--kind", "review-comment", "--last", "1", "--json"] ++ since_args,
           felt_store: felt_store
         ) do
      [event | _] ->
        resume_mode = get_in(event, ["payload", "resume_mode"])

        session_id =
          Keyword.get(opts, :session_id) ||
            latest_history_session_id(fiber_id, felt_store: felt_store)

        case {resume_mode, session_id} do
          {"previous", session_id} when is_binary(session_id) and session_id != "" ->
            {:previous, session_id}

          {"previous", _} ->
            {:error, :missing_session_id}

          _ ->
            :fresh
        end

      _ ->
        :fresh
    end
  end

  @doc """
  Returns shuttle's default felt store.

  Mirrors `Shuttle.FeltStores.configured_hosts/0` and keeps `Dispatcher`
  working standalone (e.g. via the CLI) without a running Poller.
  """
  @spec default_felt_store() :: String.t()
  def default_felt_store do
    Shuttle.FeltStores.configured_hosts()
    |> List.first()
    |> Kernel.||(System.user_home() <> "/loom")
  end

  @doc """
  Renders the universal dispatch prompt for a fiber ID.

  The prompt opens with a single orientation paragraph — what Shuttle is,
  what the worker is here to do, and how the practice gets loaded — then
  inlines exactly one context block:

    - **From User** — the most recent `review-comment` event, if any.
      The user's intent for this dispatch. Persists across handoffs
      until a newer one is filed.

  We deliberately *don't* inline the fiber's outcome or the last
  editorial event. Both are already in scope after the worker calls
  `felt show <fiber-id>` (which renders outcome + the `Recent:` line)
  and `felt history <fiber-id>` (which renders the full editorial
  chain). The shuttle skill prescribes that read order; duplicating
  either here just bloats the prompt and risks drift between the
  inlined snapshot and felt's own view.

  Why keep the From User block inlined? The user's directive isn't
  recoverable from `felt show` in the same way — it's a typed event
  among many in the history, and having it sit at the top of the
  prompt where causal attention sees it first conditions the worker's
  reading of everything that follows.

  The exit contract appears directly in the prompt, even though the full
  practice lives in the `shuttle` skill. Resumed sessions otherwise arrive
  with a lighter prompt and can mistake Shuttle work for ordinary chat
  completion; keeping `kill $PPID` in the causal foreground preserves the
  dispatcher contract across fresh and resumed runs.

  On felt failure (binary missing, no history yet) the From User block
  falls back to empty — dispatch continues rather than failing, and
  the worker just gets the orientation header.

  ## Options

    * `:felt_store` — directory containing the `.felt/` index to query.
      Defaults to `default_felt_store/0`. The Poller threads its
      configured `state.felt_store` here so each shuttle instance reads
      from the felt store it's responsible for.
  """
  @spec render_prompt(String.t(), keyword()) :: String.t()
  def render_prompt(fiber_id, opts \\ []) do
    prompt_fiber_id = Keyword.get(opts, :prompt_fiber_id, fiber_id)

    header = """
    The orchestration system Shuttle dispatched you on this fiber. The constitution describes what "done" looks like; drive toward it across one or more sessions. The `shuttle` and `felt` skills carry the practice — activate them next.

    Fiber: #{prompt_fiber_id}
    """

    compose_prompt(header, fiber_id, opts)
  end

  @doc """
  Renders the prompt injected into a *resumed* worker session.

  Mirrors the fresh dispatch prompt's From User block and exit contract so
  the resumed worker sees the same intent and termination signals at the
  top of context. The framing paragraph is shorter — skills, conventions,
  and the constitution are already in the resumed transcript, so repeating
  them is noise.

  When the latest review-comment has an empty summary (the kanban writes
  one on every requeue/resume click to keep `resume_mode` aligned with
  user intent — see `render_user_message_block/2`), the From User block
  is suppressed and the worker just gets the framing sentence.

  Pass `felt_store:` to control which `.felt/` index is queried; defaults
  to `default_felt_store/0`.
  """
  @spec render_resume_prompt(String.t(), keyword()) :: String.t()
  def render_resume_prompt(fiber_id, opts \\ []) do
    prompt_fiber_id = Keyword.get(opts, :prompt_fiber_id, fiber_id)

    header = """
    Shuttle resumed your previous session on this fiber. Skills and conventions are already loaded in your transcript from the original dispatch; pick up from the last clean checkpoint, or address the message below if one's there.

    Fiber: #{prompt_fiber_id}
    """

    compose_prompt(header, fiber_id, opts)
  end

  @doc """
  Reads the most recent `--kind review-comment` event for `fiber_id` and
  renders it as a "From User · <relative time>" block for inclusion in
  the dispatch prompt. Returns "" if there are no review-comment events,
  the latest one has an empty summary, or the latest one has already been
  consumed by a prior run (see below).

  Persistence semantics: the latest user message is shown until a worker
  run completes after it was filed. "Consumed" is derived from the existing
  editorial chain rather than a stored flag: workers append an editorial
  (`event_type: "editorial"`) handoff event at every session boundary, so
  if the most recent editorial event post-dates the latest review-comment,
  a prior run has already seen the directive and the block is suppressed.
  This stops a re-dispatch with no *new* comment from re-surfacing a stale,
  already-implemented directive as if it were a fresh task. A directive that
  has not yet been followed by any editorial event (the requeue-then-dispatch
  case) still renders. See `consumed_by_later_handoff?/3`.

  Pass `felt_store:` to control which `.felt/` index is queried.
  """
  @spec render_user_message_block(String.t(), keyword()) :: String.t()
  def render_user_message_block(fiber_id, opts \\ []) do
    case query_history(fiber_id, ["--kind", "review-comment", "--last", "1", "--json"], opts) do
      [event | _] ->
        # felt stores `--summary` text under `payload.text`. Read that key;
        # `payload.summary` was a dispatcher-side misread, never written.
        summary = (get_in(event, ["payload", "text"]) || "") |> String.trim()
        when_iso = Map.get(event, "occurred_at", "")

        cond do
          # Empty-text events: the kanban may write a review-comment carrying
          # only `resume_mode` (no user message) to keep the latest resume_mode
          # current; those should not render a From User block.
          summary == "" ->
            ""

          # Already consumed by a completed run — suppress so re-dispatch
          # without a fresh comment doesn't replay an old directive.
          consumed_by_later_handoff?(fiber_id, when_iso, opts) ->
            ""

          true ->
            render_block("From User", relative_time(when_iso), summary)
        end

      _ ->
        ""
    end
  end

  # True when the fiber has an editorial (worker handoff) event strictly newer
  # than `comment_iso` — evidence the latest review-comment was already seen by
  # a prior run. Editorial events are filed by workers at session boundaries
  # (`felt history append` with no `--kind`), so one post-dating the directive
  # means a worker has had its turn with it.
  #
  # Conservative on failure: a missing/blank/unparseable timestamp, or no
  # editorial event at all, returns false (render) so a genuinely-fresh
  # directive is never silently dropped.
  defp consumed_by_later_handoff?(_fiber_id, comment_iso, _opts)
       when not is_binary(comment_iso) or comment_iso == "",
       do: false

  defp consumed_by_later_handoff?(fiber_id, comment_iso, opts) do
    with {:ok, comment_dt, _} <- DateTime.from_iso8601(comment_iso),
         [event | _] <-
           query_history(fiber_id, ["--kind", "editorial", "--last", "1", "--json"], opts),
         editorial_iso when is_binary(editorial_iso) <- Map.get(event, "occurred_at"),
         {:ok, editorial_dt, _} <- DateTime.from_iso8601(editorial_iso) do
      DateTime.compare(editorial_dt, comment_dt) == :gt
    else
      _ -> false
    end
  end

  # Render a labeled rule-bordered block. Header is "┌─ <label>[ · <time>] ─…",
  # content is indented two spaces, closed with a matching bottom rule.
  # Total visual width is fixed at @rule_width chars so blocks align in the
  # terminal even when their headers differ in length.
  @rule_width 76
  defp render_block(label, time_suffix, content) do
    header_text =
      case time_suffix do
        nil -> label
        "" -> label
        t -> "#{label} · #{t}"
      end

    # "┌─ " (3) + header_text + " " (1) + trailing dashes = @rule_width
    leading = "┌─ #{header_text} "
    trailing = max(@rule_width - String.length(leading), 3)
    top = leading <> String.duplicate("─", trailing)
    bottom = "└" <> String.duplicate("─", @rule_width - 1)

    body = indent_block(content, "  ")

    "#{top}\n#{body}\n#{bottom}"
  end

  # Convert ISO 8601 timestamp to a relative-time phrase ("just now",
  # "5 minutes ago", "2 days ago"). Granularity tops out at coarse units
  # — we want the worker to feel the gap ("picked back up after 2 days"),
  # not the precision. Falls back to the raw string on parse failure.
  defp relative_time(""), do: ""

  defp relative_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        DateTime.utc_now()
        |> DateTime.diff(dt)
        |> max(0)
        |> format_relative()

      _ ->
        iso
    end
  end

  defp relative_time(_), do: ""

  defp format_relative(s) when s < 60, do: "just now"
  defp format_relative(s) when s < 3600, do: pluralize(div(s, 60), "minute")
  defp format_relative(s) when s < 86_400, do: pluralize(div(s, 3600), "hour")
  defp format_relative(s) when s < 2_592_000, do: pluralize(div(s, 86_400), "day")
  defp format_relative(s) when s < 31_536_000, do: pluralize(div(s, 2_592_000), "month")
  defp format_relative(s), do: pluralize(div(s, 31_536_000), "year")

  defp pluralize(1, unit), do: "1 #{unit} ago"
  defp pluralize(n, unit), do: "#{n} #{unit}s ago"

  # Shared `felt history` JSON query with graceful fallback to []. Used by
  # both the directive block (filters on --kind review-comment) and the
  # handoff block (default editorial filter). `felt_store:` opt selects the
  # `.felt/` index to query — defaults to `default_felt_store/0` so callers
  # without a configured host (e.g. CLI smoke tests) still work.
  defp query_history(fiber_id, extra_args, opts) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())
    args = ["-C", felt_store, "history", fiber_id] ++ extra_args

    case System.cmd("felt", args, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, events} when is_list(events) -> events
          _ -> []
        end

      _ ->
        []
    end
  end

  defp latest_history_session_id(fiber_id, opts) do
    fiber_id
    |> query_history(["--last", "20", "--json"], opts)
    |> Enum.find_value(fn event ->
      event
      |> get_in(["payload", "text"])
      |> extract_session_id()
    end)
  end

  defp extract_session_id(text) when is_binary(text) do
    case Regex.run(~r/(?:^|\s)session=([A-Za-z0-9._:-]+)/, text) do
      [_, "<unknown>"] -> nil
      [_, session_id] -> session_id
      _ -> nil
    end
  end

  defp extract_session_id(_), do: nil

  # Indent every line of `text` by `prefix`. Used to inset event summaries
  # under the box header so multi-line directives stay visually grouped.
  defp indent_block(text, prefix) do
    text
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&(prefix <> &1))
    |> Enum.join("\n")
  end

  @doc """
  Renders a standing-role run prompt for one scheduled occurrence.

  Mirrors the fresh dispatch prompt's shape (orientation paragraph +
  optional From User block). Standing roles are recurring fibers — this
  framing makes the run feel like one due occurrence of a durable
  responsibility rather than a new constitution. The awaiting-review
  handoff specifics (frontmatter shape on exit) live in the shuttle
  skill's "Standing Roles" section, not the prompt — keeping the prompt
  oriented and the practice in one place.
  """
  @spec render_standing_run_prompt(String.t(), String.t(), keyword()) :: String.t()
  def render_standing_run_prompt(fiber_id, run_id, opts \\ []) do
    ad_hoc? = Keyword.get(opts, :ad_hoc, false)
    prompt_fiber_id = Keyword.get(opts, :prompt_fiber_id, fiber_id)

    orientation =
      if ad_hoc? do
        "The orchestration system Shuttle dispatched you for an ad-hoc run of this standing role. Standing roles are recurring responsibilities; this dispatch is right-now work and does not consume or advance the scheduled occurrence. Exit like any standing run: write the work product into outcome, append a felt history event carrying this run id, then kill $PPID — the daemon owns the awaiting transition. The `shuttle` and `felt` skills carry the practice — activate them next."
      else
        "The orchestration system Shuttle dispatched you for a scheduled run of this standing role. Standing roles are recurring responsibilities — this dispatch is one due occurrence, not a new fiber. The `shuttle` and `felt` skills carry the practice — activate them next; the skill's \"Standing Roles\" section covers the awaiting-review handoff at run completion."
      end

    header = """
    #{orientation}
    Fiber: #{prompt_fiber_id}
    Run:   #{run_id}
    """

    compose_prompt(header, fiber_id, opts)
  end

  @doc false
  @spec prompt_fiber_id(String.t(), String.t(), String.t()) :: String.t()
  # The worker runs `felt show <id>` from inside `work_dir`, whose `.felt`
  # symlinks into a sub-store view of the loom — so the id it sees is
  # project-local (e.g. global `ai-futures/shuttle/X` → local `constitution/X`).
  # felt already computes that local address: `felt -C work_dir show <id> -j`
  # resolves the fiber against the worker's felt view and carries its
  # view-relative `id`. Read it directly rather than reconstructing it from a
  # globbed path. On any felt miss/error fall back to the global `fiber_id`,
  # preserving the previous safe-fail. `_felt_store` is retained for signature
  # stability; the worker's view is `work_dir`, not the configured store root.
  def prompt_fiber_id(fiber_id, work_dir, _felt_store) do
    case felt_show_id(work_dir, fiber_id) do
      {:ok, local_id} -> local_id
      :error -> fiber_id
    end
  end

  defp felt_show_id(work_dir, fiber_id) do
    case System.cmd("felt", ["-C", work_dir, "show", fiber_id, "-j"], stderr_to_stdout: false) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # Shared composition for all top-level prompts: a per-prompt orientation
  # header, the mandatory exit contract, and optional context blocks. The
  # shape is documented in CLAUDE.md under "Dispatch prompt structure".
  # Outcome and last-session are deliberately not inlined — the shuttle
  # skill prescribes that the worker reads them via `felt show` /
  # `felt history` on arrival, and duplicating either here risks drift
  # between the prompt's snapshot and felt's view.
  defp compose_prompt(header, fiber_id, opts) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    felt_opts = [felt_store: felt_store]

    # The store line is the worker's absolute anchor. `prompt_fiber_id`
    # translates the global id to the work_dir-local view when it can, but
    # its safe-fail hands the worker a *global* id that doesn't resolve from
    # cwd either — historically the worker then groped for the fiber. With
    # the store named, the fallback read is mechanical:
    # `felt -C <felt-store> show <id>`. (When local resolution succeeded,
    # plain `felt show <id>` from the project dir works and the line is
    # simply unused.)
    header =
      case felt_store do
        store when is_binary(store) and store != "" ->
          String.trim(header) <> "\nFelt store: #{store}"

        _ ->
          String.trim(header)
      end

    # Order: header, exit contract, user message block. The exit contract is
    # always present; the From User block carries the per-dispatch intent
    # (including any "talk to me first" signal) and renders only when there's a
    # fresh directive.
    [
      header,
      render_exit_contract(),
      render_user_message_block(fiber_id, felt_opts)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp render_exit_contract do
    render_block(
      "Exit Contract",
      nil,
      "This is an autonomous Shuttle worker. After you update outcome/history, file findings, and commit at a clean checkpoint, your final action must be `kill $PPID` — unless the dispatch directive or the constitution explicitly asks you to wait for a human (a 2FA gate, a send-in-his-voice step, a \"talk to me first\" signal); then drive to that checkpoint and stay alive there instead. Do not substitute a normal chat final response for worker exit; the handoff belongs in the fiber."
    )
  end

  # ── Capture (spawn-without-constitution) ──

  @doc """
  Spawns a tmux agent session from a free-text capture prompt — no
  pre-existing fiber required.

  The chat-to-card intake: the user's yap is carried verbatim into the
  spawned session's prompt, together with the felt store and instructions to
  crystallize the idea into a fiber, install a `shuttle:` block, claim the
  session via `POST /api/v1/claim`, and then continue as the worker realizing
  the new constitution. The session name (`capture-<hex>`) deliberately does
  NOT end in `-shuttle`: the daemon's orphan/adoption machinery ignores it
  until the worker claims it, at which point the claim verb renames the tmux
  session to the canonical `<leaf>-<uid>-shuttle` form — from then on it is
  indistinguishable from a dispatched worker.

  Options:
    * `:runner` — `Shuttle.Runner` impl (default `Shuttle.Runner.Default`)
    * `:work_dir` — project directory to spawn in (required)
    * `:felt_store` — felt store the worker should file into
    * `:agent` — agent registry name (default `"claude-fable"`)
    * `:port` — daemon HTTP port for the claim callback
    * `:host` — owning host id to stamp into the shuttle block (optional)

  Returns `{:ok, %{session:, session_uuid:, agent_id:}}` or `{:error, reason}`.
  """
  @spec capture(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture(yap, opts \\ []) when is_binary(yap) do
    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    work_dir = Keyword.fetch!(opts, :work_dir)
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())
    agent_name = Keyword.get(opts, :agent) || "claude-fable"
    port = Keyword.get(opts, :port, 4000)
    host = Keyword.get(opts, :host)

    with {:ok, agent} <- Agents.resolve_with_axes(agent_name, nil, false),
         :ok <- validate_agent(agent) do
      session = capture_session_name()

      {command, session_uuid} =
        case agent.cli do
          "claude" ->
            uuid = generate_uuid4()

            prompt =
              render_capture_prompt(yap,
                session: session,
                felt_store: felt_store,
                port: port,
                session_uuid: uuid,
                agent_id: agent.id,
                project_dir: work_dir,
                host: host
              )

            {Agents.build_command(agent, prompt, session_id: uuid), uuid}

          _ ->
            prompt =
              render_capture_prompt(yap,
                session: session,
                felt_store: felt_store,
                port: port,
                agent_id: agent.id,
                project_dir: work_dir,
                host: host
              )

            {Agents.build_command(agent, prompt), nil}
        end

      # No `session:` opt: capture sessions are headless by design (the user
      # stays on the board), so the wait-for-client gate would only delay the
      # worker by its 10s timeout.
      run_script = build_run_script(session, command, agent.id, display_fiber_id: "capture")

      Logger.info("Capture session via #{agent.id} → tmux session #{session}")

      case spawn_tmux(session, work_dir, run_script, runner) do
        {:ok, _} -> {:ok, %{session: session, session_uuid: session_uuid, agent_id: agent.id}}
        error -> error
      end
    end
  end

  @doc false
  # Public for tests. The prompt a capture session wakes to: the yap verbatim,
  # then the crystallize → install → claim → realize instructions.
  def render_capture_prompt(yap, opts) do
    session = Keyword.fetch!(opts, :session)
    felt_store = Keyword.fetch!(opts, :felt_store)
    port = Keyword.get(opts, :port, 4000)
    session_uuid = Keyword.get(opts, :session_uuid)
    agent_id = Keyword.get(opts, :agent_id, "")
    project_dir = Keyword.get(opts, :project_dir, "")
    host = Keyword.get(opts, :host)

    uuid_field =
      if session_uuid, do: ~s(, "session_uuid": "#{session_uuid}"), else: ""

    host_line =
      if is_binary(host) and host != "",
        do: "Set `host: #{host}` in the shuttle block.\n",
        else: ""

    header = """
    Shuttle capture session. The user had an idea and spoke it into the board's capture box; you are the session it spawned. Your job: crystallize the idea into a fiber, claim this session as its worker, then realize it. The `felt` and `shuttle` skills carry the practice — activate them first.

    Felt store: #{felt_store}
    Project dir: #{project_dir}

    Steps, in order (the order is load-bearing — claim BEFORE activating, or the poll loop dispatches a duplicate worker in the gap):
    1. **Crystallize.** Read the idea below and file it as a fiber in the felt store, nested under the right parent (felt-skill judgment — search for kin first). Write the lede and a `## Desired State` the idea has earned; don't over-spec a sketch.
    2. **Install the shuttle block.** Add to the fiber's frontmatter: `shuttle:` with `kind: oneshot`, `agent: #{agent_id}`, `project_dir: #{project_dir}`. #{host_line}Leave felt `status` as `open` for now.
    3. **Claim this session** (registers you with the daemon as the fiber's worker — exit handling, liveness, and the kanban all flow from this):

       curl -s -X POST http://localhost:#{port}/api/v1/claim -H 'Content-Type: application/json' -d '{"fiber_id": "<the fiber id you created>", "tmux_session": "#{session}"#{uuid_field}, "agent": "#{agent_id}"}'

       A successful claim renames this tmux session to the fiber's canonical worker name — that is expected. The claim is idempotent: if the response is lost, retry with the same body.
    4. **Activate.** Now set felt `status: active`. (Doing this before the claim would make the fiber dispatch-eligible while the daemon cannot yet see this session — a duplicate worker would spawn.)
    5. **Realize.** From here you are an ordinary Shuttle worker on that fiber: drive toward the Desired State, keep outcome/history current, and exit per the contract below.
    """

    [
      String.trim(header),
      render_exit_contract(),
      render_block("From User", nil, String.trim(yap))
    ]
    |> Enum.join("\n\n")
    |> String.trim()
  end

  # `capture-<hex>` — distinguishable, collision-free enough, and crucially
  # not `-shuttle`-suffixed (see `capture/2`).
  defp capture_session_name do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "capture-" <> suffix
  end

  @doc """
  Canonical tmux session name for a fiber, keyed by its uid.

  The form is `<leaf>-<uid>-shuttle`: the human-readable leaf keeps tmux/kitty
  titles legible from the left edge when truncated, and the uid (the fiber's
  intrinsic ULID) makes the name collision-free and rename-safe — two fibers
  sharing a leaf no longer collide, and renaming a fiber leaves the running
  worker's session addressable by the uid that does not change.

  When `uid` is `nil` or empty (legacy/test callers without a resolved uid),
  falls back to the leaf-only `<leaf>-shuttle` form.
  """
  @spec session_name(String.t(), String.t() | nil) :: String.t()
  def session_name(fiber_id, uid) when is_binary(uid) and uid != "" do
    fiber_leaf(fiber_id) <> "-" <> uid <> "-shuttle"
  end

  def session_name(fiber_id, _uid), do: session_name(fiber_id)

  @doc """
  Legacy leaf-only tmux session name (`<leaf>-shuttle`).

  Retained for **dual-recognition** during the uid-keyed cutover: live workers
  launched under the old scheme carry this name, and matching/adoption paths
  that lack a uid still recognize them. New sessions are launched under
  `session_name/2`.
  """
  @spec session_name(String.t()) :: String.t()
  def session_name(fiber_id) do
    fiber_leaf(fiber_id) <> "-shuttle"
  end

  @doc """
  Both tmux session-name forms for a fiber — the uid-keyed canonical name and
  the legacy leaf-only name — so recognition/adoption matches a live worker
  regardless of which scheme launched it. Returns `[new, legacy]` when a uid is
  available, or just `[legacy]` when it is not.
  """
  @spec session_names(String.t(), String.t() | nil) :: [String.t()]
  def session_names(fiber_id, uid) when is_binary(uid) and uid != "" do
    [session_name(fiber_id, uid), session_name(fiber_id)]
  end

  def session_names(fiber_id, _uid), do: [session_name(fiber_id)]

  @doc """
  Returns true when a tmux session name belongs to a Shuttle worker.

  Both name forms — `<leaf>-<uid>-shuttle` and the legacy `<leaf>-shuttle` —
  end in `-shuttle`, so the suffix test recognizes either.
  """
  @spec shuttle_session?(String.t()) :: boolean()
  def shuttle_session?(session_name) do
    String.ends_with?(session_name, "-shuttle")
  end

  # ── Internal ──

  defp fiber_leaf(fiber_id) do
    case String.trim_trailing(fiber_id, "/") do
      "" -> ""
      trimmed -> trimmed |> String.split("/") |> List.last()
    end
  end

  # First tries the runner's default cwd (so tests / one-off CLI invocations
  # in a project's working directory still resolve the fiber against that
  # project's `.felt/`). Falls back to the configured `felt_store` so the
  # daemon path always lands in the right index regardless of where the BEAM
  # process happens to be running. The default `felt_store` is
  # `default_felt_store/0` (~/loom) — pass `:felt_store` explicitly to point at
  # a different root.
  defp fetch_fiber(fiber_id, runner, opts) do
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())

    case run_felt(runner, ["show", fiber_id, "--json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fiber} -> {:ok, fiber}
          {:error, _} -> {:error, "invalid fiber JSON"}
        end

      {:error, _} ->
        case run_felt(runner, ["show", fiber_id, "--json"], cd: felt_store) do
          {:ok, output} ->
            case Jason.decode(output) do
              {:ok, fiber} -> {:ok, fiber}
              {:error, _} -> {:error, "invalid fiber JSON"}
            end

          {:error, _} ->
            {:error, :not_found}
        end
    end
  end

  # Reject closed fibers by default. Manual force-dispatch (the "New session"
  # / "Resume" buttons) explicitly opts in to dispatching against closed
  # fibers; `maybe_reopen_on_force/5` then reopens the YAML so the kanban
  # view actually reclassifies the card.
  defp check_not_closed(_fiber, true), do: :ok

  defp check_not_closed(fiber, _force) do
    status = Map.get(fiber, "status", "")

    if status == "closed" do
      {:error, :closed}
    else
      :ok
    end
  end

  # Force-dispatch reopens the fiber as part of the same transaction. Without
  # this, force lets the worker spawn (the closed gate above is relaxed) but
  # `status: closed`, `tempered`, and `closed_at` stay on disk — Portolan's
  # `classifyFiber` keeps the card in `awaitingReview` / `tempered` /
  # `composted` forever, even though a worker is now running. Reopen
  # (status=active, tempered cleared, closed_at cleared) lets the runningWorker
  # check classify the card as `inFlight` on the next poll.
  #
  # Skips the shell-out when the fiber is already in a clean active state —
  # re-dispatching a healthy in-flight oneshot shouldn't rewrite
  # frontmatter on every click. Failures are non-fatal: the worker can still
  # spawn; we just log the sticky-column risk loudly so it doesn't go silent
  # the way the prior "frontend orchestrates transition" path did.
  defp maybe_reopen_on_force(_fiber_id, _fiber, false, _runner, _felt_store), do: :ok

  defp maybe_reopen_on_force(fiber_id, fiber, true, runner, felt_store) do
    if already_clean?(fiber) do
      :ok
    else
      case runner.cmd(
             "shuttle-ctl",
             ["--felt-store", felt_store, "reopen", fiber_id],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          Logger.info("Force-dispatch reopened #{fiber_id}: #{String.trim(output)}")

          :ok

        {output, code} ->
          Logger.warning(
            "Force-dispatch reopen failed for #{fiber_id} " <>
              "(worker will still spawn but kanban card may stick in its prior column): " <>
              "exit #{code}: #{String.trim(output)}"
          )

          :ok
      end
    end
  end

  defp already_clean?(fiber) do
    status = Map.get(fiber, "status", "")
    tempered = Map.get(fiber, "tempered")
    closed_at = Map.get(fiber, "closed-at") || Map.get(fiber, "closed_at")

    status == "active" and is_nil(tempered) and is_nil(closed_at)
  end

  # Dual-recognition: a live worker under either the uid-keyed name or the
  # legacy leaf-only name blocks a fresh dispatch.
  defp check_not_running(fiber_id, uid, runner) do
    fiber_id
    |> session_names(uid)
    |> Enum.any?(fn session ->
      case runner.cmd("tmux", ["has-session", "-t", exact_tmux_target(session)],
             stderr_to_stdout: true
           ) do
        {_, 0} -> true
        {_, _} -> false
      end
    end)
    |> case do
      true -> {:error, :already_running}
      false -> :ok
    end
  end

  defp exact_tmux_target(session), do: "=" <> session

  defp resolve_agent(fiber) do
    # Prefer the post-migration shuttle.agent field when present; fall back
    # to legacy tag-based resolution (agent:<name> compound + bare aliases).
    # `felt show --json` rounds-trip-the-bytes (felt v1.0.4+): tool-owned
    # frontmatter namespaces like `shuttle:` and `tags:` appear as flat
    # top-level JSON keys.
    effort = get_in(fiber, ["shuttle", "effort"])
    chrome = get_in(fiber, ["shuttle", "chrome"]) == true

    base =
      case get_in(fiber, ["shuttle", "agent"]) do
        name when is_binary(name) and name != "" ->
          Agents.resolve_by_name(name)

        _ ->
          tags = Map.get(fiber, "tags", [])
          Agents.resolve(tags)
      end

    # Overlay the block's effort/chrome axes onto the resolved base agent,
    # validating against per-harness constraints. apply_axes also expands an
    # alias record (e.g. claude-opus-chrome → claude-opus + chrome).
    with {:ok, agent} <- base do
      Agents.apply_axes(agent, effort, chrome)
    end
  end

  defp validate_agent(agent) do
    if agent.requires_model and is_nil(agent.model) do
      {:error, "agent #{agent.id} requires a model but none configured"}
    else
      :ok
    end
  end

  # Dispatch: fresh worker (new session) or resume previous.
  # `resume_intent` is `:fresh | {:previous, session_id}` from check_resume_intent/3.
  defp create_tmux_session(fiber_id, agent, work_dir, runner, prompt_context, resume_intent, opts) do
    session = session_name(fiber_id, Keyword.get(opts, :uid))
    felt_store = Keyword.get(opts, :felt_store, default_felt_store())
    worker_fiber_id = prompt_fiber_id(fiber_id, work_dir, felt_store)

    prompt_opts =
      opts
      |> Keyword.put(:work_dir, work_dir)
      |> Keyword.put(:prompt_fiber_id, worker_fiber_id)

    case resume_intent do
      {:previous, session_id} ->
        # Resume mode: invoke the harness-appropriate resume command and
        # inject a small prompt as the next user turn so the resumed
        # worker knows it was deliberately woken (and sees the user's
        # latest directive if there is one). Without this the worker
        # would wake blind to the directive that triggered the resume.
        Logger.info(
          "Resuming #{fiber_id} session #{session_id} via #{agent.id} → tmux #{session}"
        )

        resume_prompt = render_resume_prompt(fiber_id, prompt_opts)
        command = Agents.build_resume_command(agent, session_id, resume_prompt)

        # claude --resume shows an interactive "you're about to use a
        # previous session" warning that only an Enter keypress at the
        # TTY can dismiss. The heredoc-piped prompt arrives *after* the
        # warning, so we can't fold it in. Schedule a tmux send-keys to
        # fire a couple seconds in. Other harnesses (codex/pi) don't
        # show this warning.
        run_script =
          build_run_script(fiber_id, command, agent.id,
            dismiss_resume_warning: agent.cli == "claude",
            session: session,
            display_fiber_id: worker_fiber_id
          )

        spawn_tmux(session, work_dir, run_script, runner)

      :fresh ->
        # Fresh mode: build the full dispatch prompt.
        {command, session_uuid} =
          build_fresh_command(agent, fiber_id, prompt_context, prompt_opts)

        Logger.info("Dispatching #{fiber_id} via #{agent.id} → tmux session #{session}")

        run_script =
          build_run_script(fiber_id, command, agent.id, display_fiber_id: worker_fiber_id)

        case spawn_tmux(session, work_dir, run_script, runner) do
          {:ok, _} = result ->
            # Store the session UUID so "Resume previous" is available next time.
            if Keyword.get(opts, :store_session_id, true) do
              store_session_id(fiber_id, agent.id, session_uuid, runner, felt_store)
            end

            result

          error ->
            error
        end
    end
  end

  # Build the fresh dispatch command. For Claude we generate and inject a UUID
  # upfront (--session-id) so we can store it synchronously. For codex/pi we
  # dispatch normally and capture the UUID asynchronously after spawn.
  defp build_fresh_command(agent, fiber_id, prompt_context, opts) do
    prompt = render_context_prompt(fiber_id, prompt_context, opts)
    prompt_fiber_id = Keyword.get(opts, :prompt_fiber_id, fiber_id)

    case agent.cli do
      "claude" ->
        uuid = generate_uuid4()
        command = Agents.build_command(agent, prompt, session_id: uuid)
        {command, {:claude, uuid}}

      cli when cli in ["codex", "pi"] ->
        command = Agents.build_command(agent, prompt)
        work_dir = Keyword.get(opts, :work_dir, File.cwd!())
        {command, {:capture, cli, work_dir, prompt_fiber_id, DateTime.utc_now()}}

      _ ->
        command = Agents.build_command(agent, prompt)
        {command, :none}
    end
  end

  # Spawn a tmux session from a run-script string.
  defp spawn_tmux(session, work_dir, run_script, runner) do
    tmp_path =
      Path.join(System.tmp_dir!(), "shuttle-run-#{System.unique_integer([:positive])}.sh")

    File.write!(tmp_path, run_script)
    File.chmod!(tmp_path, 0o755)

    args = ["new-session", "-d", "-s", session, "-c", work_dir, "bash", "-l", tmp_path]

    case runner.cmd("tmux", args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Worker running: tmux attach -t #{session}")
        {:ok, session}

      {output, _} ->
        File.rm(tmp_path)
        {:error, "tmux failed: #{output}"}
    end
  end

  # Record the session UUID in felt history after a successful fresh dispatch, so
  # "Resume previous" can recover it across a daemon restart. felt history is the
  # chronological substrate and the only durable session-id home post-slice-6 (no
  # runtime store, no doc-resident `shuttle.session` block); `latest_history_
  # session_id` parses the `session=<uuid>` token back out at the next dispatch,
  # and the worker-exit event reads it the same way.
  # - Claude: UUID was pre-specified; write synchronously (fire-and-forget Task).
  # - Codex/Pi: capture UUID from session file asynchronously with backoff.
  # - None: agent doesn't support session IDs; skip.
  defp store_session_id(fiber_id, agent_id, {:claude, uuid}, _runner, felt_store) do
    # Fire-and-forget: recording the UUID is best-effort; blocking dispatch on a
    # felt write would delay WorkerWatcher startup and cause flaky tests.
    Task.start(fn ->
      record_dispatch_session(fiber_id, agent_id, uuid, felt_store)
    end)
  end

  defp store_session_id(
         fiber_id,
         agent_id,
         {:capture, cli, work_dir, capture_fiber_id, dispatched_after},
         _runner,
         felt_store
       ) do
    # Fire-and-forget: capture the session UUID from the harness's JSONL file
    # in a background task. The race window (50 ms × 20 attempts = ~1 s) is
    # short enough that the kanban card will show "Resume previous" by the
    # next manual refresh.
    Task.start(fn ->
      case capture_session_uuid(cli, work_dir, capture_fiber_id, dispatched_after, 100) do
        {:ok, uuid} ->
          record_dispatch_session(fiber_id, agent_id, uuid, felt_store)

        {:error, reason} ->
          Logger.warning(
            "Could not capture session UUID for #{fiber_id} (#{cli}): #{reason}. " <>
              "Resume previous will be unavailable."
          )
      end
    end)
  end

  defp store_session_id(_fiber_id, _agent_id, :none, _runner, _felt_store), do: :ok

  # Append a felt-history event carrying the dispatch session UUID. The summary
  # uses the same `session=<uuid>` token the worker-exit event uses, so
  # `latest_history_session_id`/`extract_session_id` recover it uniformly.
  defp record_dispatch_session(fiber_id, agent_id, uuid, felt_store) do
    store = felt_store || default_felt_store()
    summary = "worker dispatched (agent=#{agent_id}) session=#{uuid}"

    case System.cmd("felt", ["-C", store, "history", "append", fiber_id, "--summary", summary],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        Logger.info("Recorded session UUID #{uuid} for #{fiber_id} in felt history")

      {output, code} ->
        Logger.warning(
          "Could not record session UUID for #{fiber_id} (felt exit #{code}): #{String.trim(output)}"
        )
    end
  rescue
    e -> Logger.warning("Could not record session UUID for #{fiber_id}: #{inspect(e)}")
  end

  # Poll for the session UUID written by codex/pi to their respective session
  # JSONL files. Tries `attempts` times with 50 ms between each.
  #
  # Disk layouts:
  #   codex: ~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl
  #          First line: {"type":"session_meta","payload":{"id":"<uuid>","cwd":"..."}}
  #   pi:    ~/.pi/agent/sessions/<encoded-cwd>/<iso>_<uuid>.jsonl
  #          First line: {"type":"session","id":"<uuid>","cwd":"..."}
  #
  # Codex stores all sessions in one date directory, so cwd alone is not a
  # unique worker identity: the human can be driving an interactive Codex
  # thread from the same project while Shuttle dispatches a worker. Require
  # the transcript to be new enough for this dispatch and to contain Shuttle's
  # fiber prompt before accepting its UUID.
  defp capture_session_uuid(_cli, _work_dir, _fiber_id, _dispatched_after, 0) do
    {:error, "timed out waiting for session file"}
  end

  defp capture_session_uuid(cli, work_dir, fiber_id, dispatched_after, attempts) do
    :timer.sleep(50)

    case find_session_file(cli, work_dir, fiber_id, dispatched_after) do
      {:ok, path} ->
        read_uuid_from_jsonl(cli, path, work_dir)

      {:error, _} ->
        capture_session_uuid(cli, work_dir, fiber_id, dispatched_after, attempts - 1)
    end
  end

  defp find_session_file("codex", work_dir, fiber_id, dispatched_after) do
    dir = codex_sessions_dir()

    case File.ls(dir) do
      {:ok, files} ->
        paths =
          files
          |> Enum.filter(&String.starts_with?(&1, "rollout-"))
          |> Enum.sort(:desc)
          |> Enum.map(&Path.join(dir, &1))

        case Enum.find(paths, &codex_session_matches?(&1, work_dir, fiber_id, dispatched_after)) do
          nil -> {:error, :not_found}
          path -> {:ok, path}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_session_file("pi", work_dir, _fiber_id, _dispatched_after) do
    home = System.user_home!()
    # Pi's encoded-cwd: absolute path with "/" replaced by "-", bracketed by "--".
    # e.g. /home/user/loom → --home-user-loom--
    encoded = "--" <> String.replace(work_dir, "/", "-") <> "--"
    dir = Path.join([home, ".pi", "agent", "sessions", encoded])

    case File.ls(dir) do
      {:ok, files} ->
        sorted = Enum.sort(files)

        case List.last(sorted) do
          nil -> {:error, :not_found}
          file -> {:ok, Path.join(dir, file)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_session_file(_cli, _work_dir, _fiber_id, _dispatched_after),
    do: {:error, :unsupported}

  defp codex_sessions_dir do
    case System.get_env("SHUTTLE_CODEX_SESSIONS_DIR") do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        home = System.user_home!()
        date = Date.utc_today()
        Path.join([home, ".codex", "sessions", "#{date.year}", pad2(date.month), pad2(date.day)])
    end
  end

  defp codex_session_matches?(path, work_dir, fiber_id, dispatched_after) do
    with {:ok, content} <- File.read(path),
         [first_line | _] <- String.split(content, "\n", parts: 2),
         {:ok, event} <- Jason.decode(first_line),
         "session_meta" <- Map.get(event, "type"),
         payload when is_map(payload) <- Map.get(event, "payload"),
         cwd when is_binary(cwd) <- Map.get(payload, "cwd"),
         timestamp when is_binary(timestamp) <- Map.get(payload, "timestamp"),
         {:ok, started_at, _} <- DateTime.from_iso8601(timestamp) do
      Path.expand(cwd) == Path.expand(work_dir) and
        DateTime.compare(started_at, DateTime.add(dispatched_after, -5, :second)) != :lt and
        String.contains?(content, "Fiber: #{fiber_id}")
    else
      _ -> false
    end
  end

  defp read_uuid_from_jsonl("codex", path, work_dir) do
    with {:ok, content} <- File.read(path),
         first_line <- content |> String.split("\n") |> List.first(""),
         {:ok, event} <- Jason.decode(first_line),
         "session_meta" <- Map.get(event, "type"),
         payload when is_map(payload) <- Map.get(event, "payload"),
         uuid when is_binary(uuid) and uuid != "" <- Map.get(payload, "id"),
         cwd when is_binary(cwd) <- Map.get(payload, "cwd") do
      # Verify the session belongs to this worker's working directory.
      if Path.expand(cwd) == Path.expand(work_dir) do
        {:ok, uuid}
      else
        {:error, "session cwd mismatch: #{cwd} ≠ #{work_dir}"}
      end
    else
      _ -> {:error, "could not parse session UUID from #{path}"}
    end
  end

  defp read_uuid_from_jsonl("pi", path, work_dir) do
    with {:ok, content} <- File.read(path),
         first_line <- content |> String.split("\n") |> List.first(""),
         {:ok, event} <- Jason.decode(first_line),
         "session" <- Map.get(event, "type"),
         uuid when is_binary(uuid) and uuid != "" <- Map.get(event, "id"),
         cwd when is_binary(cwd) <- Map.get(event, "cwd") do
      if Path.expand(cwd) == Path.expand(work_dir) do
        {:ok, uuid}
      else
        {:error, "session cwd mismatch: #{cwd} ≠ #{work_dir}"}
      end
    else
      _ -> {:error, "could not parse session UUID from #{path}"}
    end
  end

  defp read_uuid_from_jsonl(_cli, path, _work_dir),
    do: {:error, "unsupported harness for #{path}"}

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  # Generates a random UUID v4 using Erlang's :crypto module.
  # Sets version bits (byte 6 top nibble = 0100) and variant bits
  # (byte 8 top 2 bits = 10) per RFC 4122.
  defp generate_uuid4 do
    <<b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15>> =
      :crypto.strong_rand_bytes(16)

    v6 = (b6 &&& 0x0F) ||| 0x40
    v8 = (b8 &&& 0x3F) ||| 0x80

    :io_lib.format(
      "~2.16.0b~2.16.0b~2.16.0b~2.16.0b-~2.16.0b~2.16.0b-~2.16.0b~2.16.0b-~2.16.0b~2.16.0b-~2.16.0b~2.16.0b~2.16.0b~2.16.0b~2.16.0b~2.16.0b",
      [b0, b1, b2, b3, b4, b5, v6, b7, v8, b9, b10, b11, b12, b13, b14, b15]
    )
    |> IO.chardata_to_string()
  end

  defp render_context_prompt(fiber_id, {:standing_run, run_id}, opts) do
    render_standing_run_prompt(fiber_id, run_id, opts)
  end

  defp render_context_prompt(fiber_id, {:standing_run, run_id, :ad_hoc}, opts) do
    render_standing_run_prompt(fiber_id, run_id, Keyword.put(opts, :ad_hoc, true))
  end

  defp render_context_prompt(fiber_id, _, opts), do: render_prompt(fiber_id, opts)

  @doc false
  # Public for tests. Builds the bash script that wraps the harness command
  # with start/exit banners. With `dismiss_resume_warning: true` and a
  # `session:` name, also schedules a backgrounded tmux send-keys to
  # dismiss claude --resume's interactive warning page.
  def build_run_script(fiber_id, command, agent_id, opts \\ []) do
    dismiss_resume_warning = Keyword.get(opts, :dismiss_resume_warning, false)
    session = Keyword.get(opts, :session, "")
    display_fiber_id = Keyword.get(opts, :display_fiber_id, fiber_id)

    # When resuming claude, schedule a backgrounded tmux send-keys to
    # dismiss the interactive warning page. Runs *inside* the same tmux
    # session it's targeting — tmux send-keys can target the current
    # session, the keypress lands on whatever's at the prompt (claude's
    # warning UI). 2 seconds is a safety margin for claude startup.
    dismiss_block =
      if dismiss_resume_warning and session != "" do
        # Single-quote the session name so slashes/dots don't trip the shell.
        ~s|( sleep 2; tmux send-keys -t '#{session}' Enter ) &\n    |
      else
        ""
      end

    # Wait briefly for a real interactive tmux client (e.g. kitty's
    # `tmux attach`) to attach before starting the harness. We spawn the
    # tmux session detached (`tmux new-session -d ...`), which inherits
    # the server's `default-size` (80x24 by default). If the harness
    # starts rendering before a human-sized client attaches, its initial
    # output — especially `claude --resume`, which emits the dispatch
    # banner and "remote-control is active" line as soon as it loads
    # saved state — bakes into the scrollback at 80 cols and stays there
    # even after tmux resizes on attach (resize doesn't reflow scrollback).
    # The user sees a tiny ~80-col-wide content area inside a much larger
    # kitty tab. Waiting until the first non-control client attaches lets
    # the harness initialize at the kitty terminal's real size.
    #
    # Control-mode clients (Portolan's `tmux -C attach -r` wterm preview)
    # don't count — they declare a fake 200x50 and don't represent a
    # human attach. Filter them out via `client_control_mode=0`.
    #
    # The expected client of this gate is Portolan's auto-attach in the
    # kanban modal's dispatch-success path (`onAttachFreshTmux` → kitty
    # `launch --type=tab tmux attach`), which lands in ~300-500ms. The
    # 10s timeout is the safety net for the rare cases where that auto-
    # attach can't run — kitty isn't running, the daemon was dispatched
    # by a non-Portolan client (CLI, scheduled standing role with no
    # human in the loop). After the timeout the harness proceeds at the
    # default-size, same as the world before this gate existed.
    wait_for_client_block =
      if session != "" do
        ~s"""
        WAIT_DEADLINE=$(( $(date +%s) + 10 ))
        while [ "$(date +%s)" -lt "$WAIT_DEADLINE" ]; do
          if tmux list-clients -t '#{session}' -F '\#{client_control_mode}' 2>/dev/null | grep -qx '0'; then
            break
          fi
          sleep 0.2
        done
        """
      else
        ""
      end

    """
    #!/bin/bash
    set -e
    trap 'rm -f "$0"' EXIT

    #{wait_for_client_block}
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Shuttle worker — #{display_fiber_id} — agent=#{agent_id} — $(date '+%H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    #{dismiss_block}#{command}

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Shuttle worker exited (agent=#{agent_id})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    """
  end

  defp run_felt(runner, args, opts \\ []) do
    cd = Keyword.get(opts, :cd)

    cmd_opts =
      if cd do
        [cd: cd, stderr_to_stdout: true]
      else
        [stderr_to_stdout: true]
      end

    case runner.cmd("felt", args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end
end
