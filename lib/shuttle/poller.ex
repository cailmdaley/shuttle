defmodule Shuttle.Poller do
  @moduledoc """
  Polls the felt fiber tree and dispatches workers for eligible constitutions.

  A single GenServer owns the dispatch tick, eligibility predicate, retry
  scheduling, and reconciliation. It starts `Shuttle.WorkerWatcher` processes
  under a `DynamicSupervisor` to track each worker's tmux session from outside.

  Lifted from Symphony's orchestrator.ex with the integration layer replaced:
  - Linear API → felt CLI
  - Issue model → fiber model
  - Codex app-server → tmux + agent CLI wrappers

  ## Multi-host support

  The Poller manages one or more felt stores on the same machine. Configure via:

      config :shuttle, felt_stores: ["~/loom", "~/other-project"]
      # or env var (comma-separated, takes precedence over the persisted file):
      LOOM_HOMES=~/loom,~/other-project
      # or persisted registration written through the HTTP API:
      ~/.shuttle/felt_stores.json

  Single-host setups (the common case) are unchanged: when no explicit hosts
  are configured, Shuttle falls back to `[LOOM_HOME || ~/loom]`.

  Each fiber resolves to exactly one host: the first configured host whose
  `.felt/` directory contains the fiber file. The resolution is cached in
  `State.fiber_host_cache` for the daemon's lifetime. Call
  `bust_fiber_host_cache/1` or `POST /api/v1/cache/bust` to evict an entry
  when a fiber moves between hosts.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Shuttle.{Actions, Dispatcher, RuntimeStore, StandingRole, WorkerWatcher}

  @pubsub_topic "shuttle:snapshot"

  @default_poll_interval_ms 30_000
  @default_max_concurrent_workers 10
  @default_heartbeat_interval_ms 5_000
  @default_stall_timeout_ms 300_000
  @dispatch_call_timeout_ms 30_000
  @orchestrator_state_call_timeout_ms 30_000
  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @default_max_retry_backoff_ms 300_000
  @felt_shuttle_projection_fields "id,status,created_at,shuttle,depends_on,tempered"

  defmodule State do
    @moduledoc false
    defstruct [
      # Stable reference for cross-process messaging (e.g. WorkerWatcher →
      # Poller exit notifications). Captured from the Poller's registered
      # name in init/1, falling back to self()'s pid if unnamed (test
      # scenarios). Watchers store this as `:poller` and `send/2` resolves
      # the registered atom at delivery time, which survives a Poller
      # supervisor restart — pids do not (the old pid is dead, sends are
      # silently dropped, and `state.running` ghosts forever). See
      # [[ai-futures/shuttle/finding-ghost-workers-stuck-running]].
      :self_ref,
      :poll_interval_ms,
      :max_concurrent_workers,
      :heartbeat_interval_ms,
      :stall_timeout_ms,
      :max_retry_backoff_ms,
      :next_poll_due_at_ms,
      :tick_timer_ref,
      :tick_token,
      # List of felt store directories, in resolution-priority order.
      :felt_stores,
      # Machine identity used by shuttle.host dispatch affinity.
      :own_host_id,
      # Host-local SQLite file where daemon runtime state is persisted.
      :runtime_store_path,
      # When true, felt_stores is re-read from env + persisted registration on
      # each poll cycle. Set true when :felt_stores opt isn't passed to
      # start_link; false when the caller passed an explicit list (tests,
      # manual overrides — respect them).
      :auto_discover_felt_stores,
      :runner,
      poll_check_in_progress: false,
      running: %{},
      claimed: MapSet.new(),
      retry_queue: %{},
      waiters: %{},
      reservations: %{},
      completed_standing_runs: MapSet.new(),
      standing_roles: [],
      orphans: [],
      # %{fiber_id => felt_store} — populated by discover_candidates/1 on each
      # poll cycle and by host_for_fiber/2 on demand. Entries are never evicted
      # automatically; call bust_fiber_host_cache/1 when a fiber moves hosts.
      fiber_host_cache: %{},
      # %{fiber_id => %{reason: term, attempted_at: DateTime.t, attempts:
      # pos_integer}} — fibers the dispatcher rejected with an error other
      # than :already_running. Surfaced in the snapshot's `blocked` list so
      # the kanban shows *why* a fiber isn't progressing instead of leaving
      # the poll-cycle warning to scroll unread in the daemon log. Entries
      # clear on successful dispatch or when the fiber's eligibility changes
      # (frontmatter edit, pause, close).
      dispatch_failures: %{}
    ]
  end

  # ── Client ──

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot() :: map()
  def snapshot, do: snapshot(__MODULE__)

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @spec snapshot(GenServer.server(), non_neg_integer()) :: map()
  def snapshot(server, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.call(server, :snapshot, timeout_ms)
  end

  # ── Agent-API Client ──

  @spec worker_status(String.t()) :: map() | nil
  def worker_status(fiber_id), do: worker_status(__MODULE__, fiber_id)

  @spec worker_status(GenServer.server(), String.t()) :: map() | nil
  def worker_status(server, fiber_id) do
    GenServer.call(server, {:worker_status, fiber_id})
  end

  @spec dispatch_fiber(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def dispatch_fiber(fiber_id, opts \\ []), do: dispatch_fiber(__MODULE__, fiber_id, opts)

  @spec dispatch_fiber(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def dispatch_fiber(server, fiber_id, opts) do
    GenServer.call(server, {:dispatch, fiber_id, opts}, @dispatch_call_timeout_ms)
  end

  @spec actions_for(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def actions_for(fiber_id, opts \\ []), do: actions_for(__MODULE__, fiber_id, opts)

  @spec actions_for(GenServer.server(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def actions_for(server, fiber_id, opts) do
    GenServer.call(server, {:actions, fiber_id, opts}, @dispatch_call_timeout_ms)
  end

  @spec actions_for(GenServer.server(), String.t(), keyword(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def actions_for(server, fiber_id, opts, timeout_ms) do
    GenServer.call(server, {:actions, fiber_id, opts}, timeout_ms)
  end

  @spec resolve_action(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_action(fiber_id, target, opts \\ []),
    do: resolve_action(__MODULE__, fiber_id, target, opts)

  @spec resolve_action(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_action(server, fiber_id, target, opts) do
    GenServer.call(server, {:resolve_action, fiber_id, target, opts}, @dispatch_call_timeout_ms)
  end

  @spec resolve_action(GenServer.server(), String.t(), String.t(), keyword(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def resolve_action(server, fiber_id, target, opts, timeout_ms) do
    GenServer.call(server, {:resolve_action, fiber_id, target, opts}, timeout_ms)
  end

  @spec wait_for_tempered(String.t(), non_neg_integer(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def wait_for_tempered(fiber_id, timeout_ms, opts \\ []),
    do: wait_for_tempered(__MODULE__, fiber_id, timeout_ms, opts)

  @spec wait_for_tempered(GenServer.server(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, atom()} | {:error, term()}
  def wait_for_tempered(server, fiber_id, timeout_ms, opts) do
    GenServer.call(server, {:wait, fiber_id, timeout_ms, opts})
  end

  @spec reserve_resource(String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, atom()} | {:error, String.t()}
  def reserve_resource(resource, host, duration_ms, fiber_id),
    do: reserve_resource(__MODULE__, resource, host, duration_ms, fiber_id)

  @spec reserve_resource(
          GenServer.server(),
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t()
        ) :: {:ok, atom()} | {:error, String.t()}
  def reserve_resource(server, resource, host, duration_ms, fiber_id) do
    GenServer.call(server, {:reserve, resource, host, duration_ms, fiber_id})
  end

  @spec orchestrator_state() :: map()
  def orchestrator_state, do: orchestrator_state(__MODULE__)

  @spec orchestrator_state(GenServer.server()) :: map()
  def orchestrator_state(server) do
    GenServer.call(server, :orchestrator_state, @orchestrator_state_call_timeout_ms)
  end

  @spec orchestrator_state(GenServer.server(), non_neg_integer()) :: map()
  def orchestrator_state(server, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    GenServer.call(server, :orchestrator_state, timeout_ms)
  end

  @doc """
  Returns `{:ok, felt_store}` for the first configured host that contains
  `fiber_id`, or `{:error, :not_found}` if the fiber isn't in any host.

  The result is cached in the Poller's state for the daemon's lifetime.
  Used by `GET /api/v1/fiber/:id/host` so external callers can route their
  felt operations to the right index without re-implementing host resolution.
  """
  @spec resolve_fiber_host(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve_fiber_host(fiber_id), do: resolve_fiber_host(__MODULE__, fiber_id)

  @spec resolve_fiber_host(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found}
  def resolve_fiber_host(server, fiber_id) do
    GenServer.call(server, {:resolve_fiber_host, fiber_id})
  end

  @doc """
  Evicts the cached felt-store resolution for `fiber_id`. The daemon
  re-resolves on the next access. Use after a fiber moves between hosts.
  """
  @spec bust_fiber_host_cache(String.t()) :: :ok
  def bust_fiber_host_cache(fiber_id), do: bust_fiber_host_cache(__MODULE__, fiber_id)

  @spec bust_fiber_host_cache(GenServer.server(), String.t()) :: :ok
  def bust_fiber_host_cache(server, fiber_id) do
    GenServer.call(server, {:bust_fiber_host_cache, fiber_id})
  end

  # ── Server ──

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)

    {felt_stores, auto_discover} =
      case Keyword.fetch(opts, :felt_stores) do
        {:ok, hosts} -> {hosts, false}
        :error -> {default_felt_stores(), true}
      end

    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)
    own_host_id = Keyword.get(opts, :own_host_id, resolve_own_host_id())

    # Use the registered name (atom) when available so cross-process sends
    # survive a supervisor restart of this Poller. Process.info/2 returns
    # `{:registered_name, atom}` for named processes and `{:registered_name, []}`
    # for unnamed ones (typical in tests started without a `name:` opt; we fall
    # back to self() pid so behavior is unchanged in that case).
    self_ref =
      case Process.info(self(), :registered_name) do
        {:registered_name, name} when is_atom(name) -> name
        _ -> self()
      end

    runtime_store_path =
      Keyword.get_lazy(opts, :runtime_store_path, &default_runtime_store_path/0)

    :ok = RuntimeStore.init(runtime_store_path)

    state = %State{
      self_ref: self_ref,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      max_concurrent_workers:
        Keyword.get(opts, :max_concurrent_workers, @default_max_concurrent_workers),
      heartbeat_interval_ms:
        Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms),
      stall_timeout_ms: Keyword.get(opts, :stall_timeout_ms, @default_stall_timeout_ms),
      max_retry_backoff_ms:
        Keyword.get(opts, :max_retry_backoff_ms, @default_max_retry_backoff_ms),
      next_poll_due_at_ms: now_ms,
      tick_timer_ref: nil,
      tick_token: nil,
      felt_stores: felt_stores,
      own_host_id: to_string(own_host_id),
      runtime_store_path: runtime_store_path,
      auto_discover_felt_stores: auto_discover,
      runner: runner
    }

    Logger.info("configured felt stores: #{inspect(felt_stores)}")

    # Rehydrate the daemon-owned runtime store first, then adopt any live tmux
    # sessions that predate the store or were created while the daemon was down.
    state = state |> rehydrate_runtime_store() |> adopt_orphans() |> rehydrate_retry_queue()

    # Schedule first tick immediately
    state = schedule_tick(state, 0)
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = %{
      state
      | next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    :ok = schedule_poll_cycle()
    {:noreply, state}
  end

  def handle_info({:tick, _}, state), do: {:noreply, state}

  def handle_info(:run_poll_cycle, %{poll_check_in_progress: true} = state), do: {:noreply, state}

  def handle_info(:run_poll_cycle, state) do
    parent = self()

    {:ok, _pid} =
      Task.start_link(fn ->
        send(parent, {:poll_cycle_complete, run_poll_cycle_safely(state)})
      end)

    {:noreply, %{state | poll_check_in_progress: true}}
  end

  def handle_info({:poll_cycle_complete, {:ok, poll_state}}, state) do
    state =
      state
      |> merge_poll_cycle_state(poll_state)
      |> Map.put(:poll_check_in_progress, false)
      |> schedule_tick(state.poll_interval_ms)

    broadcast_snapshot(state)
    {:noreply, state}
  end

  def handle_info({:poll_cycle_complete, {:error, reason}}, state) do
    Logger.error("Poll cycle failed: #{reason}")

    state =
      state
      |> Map.put(:poll_check_in_progress, false)
      |> schedule_tick(state.poll_interval_ms)

    broadcast_snapshot(state)
    {:noreply, state}
  end

  def handle_info({:worker_exited, fiber_id, reason, session_alive?}, state) do
    state = handle_worker_exit(state, fiber_id, reason, session_alive?)
    broadcast_snapshot(state)
    {:noreply, state}
  end

  def handle_info({:retry, fiber_id, retry_token}, state) do
    result =
      case pop_retry(state, fiber_id, retry_token) do
        {:ok, retry, state} -> handle_retry(state, fiber_id, retry)
        :missing -> {:noreply, state}
      end

    result
  end

  def handle_info({:retry, _}, state), do: {:noreply, state}

  def handle_info({:wait_timeout, fiber_id, waiter_id}, state) do
    waiters = Map.get(state.waiters, fiber_id, [])
    {timed_out, remaining} = Enum.split_with(waiters, fn waiter -> waiter.id == waiter_id end)

    Enum.each(timed_out, fn waiter ->
      if waiter.pid, do: send(waiter.pid, {:wait_timeout, fiber_id})

      if waiter.channel_topic do
        Phoenix.PubSub.broadcast(Shuttle.PubSub, waiter.channel_topic, %{
          event: "timed_out",
          fiber_id: fiber_id
        })
      end
    end)

    new_waiters =
      if remaining == [],
        do: Map.delete(state.waiters, fiber_id),
        else: Map.put(state.waiters, fiber_id, remaining)

    {:noreply, %{state | waiters: new_waiters}}
  end

  def handle_info(msg, state) do
    Logger.debug("Poller ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call({:worker_status, fiber_id}, _from, state) do
    {:reply, Map.get(state.running, fiber_id), state}
  end

  def handle_call({:dispatch, fiber_id, opts}, _from, state) do
    state = reconcile_running_fiber(state, fiber_id)
    session = Dispatcher.session_name(fiber_id)

    cond do
      Map.has_key?(state.running, fiber_id) or MapSet.member?(state.claimed, fiber_id) ->
        {:reply, {:error, :already_running}, state}

      already_running_session?(state, session) ->
        {:reply, {:error, :already_running}, state}

      true ->
        case fetch_fiber_full(fiber_id, state) do
          {:ok, fiber} ->
            cond do
              # Human-worker fibers: the user works on them themselves;
              # there's no actual dispatch to do. Reply success without
              # touching state so the caller (kanban modal) closes
              # cleanly and the card stays in inFlight.
              human_worker?(fiber) ->
                Logger.info("API dispatch for #{fiber_id} is human-worker; no-op")
                {:reply, {:ok, "human"}, state}

              error = awaiting_ad_hoc_dispatch_error(fiber, state, opts) ->
                {:reply, error, state}

              dispatch_eligible?(fiber, state, opts) ->
                {new_state, result} = do_dispatch_fiber(state, fiber, opts)
                {:reply, result || {:ok, session}, new_state}

              true ->
                {:reply, {:error, :not_eligible}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:actions, fiber_id, opts}, _from, state) do
    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        running? = Keyword.get(opts, :running, Map.has_key?(state.running, fiber_id))
        {:reply, {:ok, Actions.actions_for(fiber, running?)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_action, fiber_id, target, opts}, _from, state) do
    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        running? = Keyword.get(opts, :running, Map.has_key?(state.running, fiber_id))
        {:reply, Actions.resolve_transition(fiber, target, running?), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:wait, fiber_id, timeout_ms, opts}, _from, state) do
    channel_topic = Keyword.get(opts, :channel_topic)
    notify_pid = Keyword.get(opts, :notify_pid)
    waiter_id = Keyword.get(opts, :waiter_id, make_ref())

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        if Map.get(fiber, "tempered", false) do
          if notify_pid, do: send(notify_pid, {:tempered, fiber_id})

          if channel_topic do
            Phoenix.PubSub.broadcast(Shuttle.PubSub, channel_topic, %{
              event: "tempered",
              fiber_id: fiber_id
            })
          end

          {:reply, {:ok, :already_tempered}, state}
        else
          timeout_ref =
            Process.send_after(self(), {:wait_timeout, fiber_id, waiter_id}, timeout_ms)

          waiters = Map.get(state.waiters, fiber_id, [])
          waiters = replace_matching_waiter(waiters, channel_topic, notify_pid)

          waiters = [
            %{
              id: waiter_id,
              pid: notify_pid,
              timeout_ref: timeout_ref,
              channel_topic: channel_topic
            }
            | waiters
          ]

          {:reply, {:ok, :monitoring},
           %{state | waiters: Map.put(state.waiters, fiber_id, waiters)}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reserve, resource, host, duration_ms, fiber_id}, _from, state) do
    key = {resource, host}
    state = clean_expired_reservations(state)
    now_ms = System.monotonic_time(:millisecond)

    case Map.get(state.reservations, key) do
      nil ->
        expires_at = now_ms + duration_ms
        reservation = %{fiber_id: fiber_id, expires_at_ms: expires_at}

        {:reply, {:ok, :reserved},
         %{state | reservations: Map.put(state.reservations, key, reservation)}}

      existing ->
        {:reply, {:error, "already reserved by #{existing.fiber_id}"}, state}
    end
  end

  def handle_call(:orchestrator_state, _from, state) do
    state = clean_expired_reservations(state)
    {:reply, build_full_state(state), state}
  end

  def handle_call({:resolve_fiber_host, fiber_id}, _from, state) do
    case host_for_fiber(fiber_id, state) do
      {:ok, host} ->
        # Cache the result so subsequent calls and file-stat probes within
        # the same daemon lifetime return quickly.
        new_state = %{state | fiber_host_cache: Map.put(state.fiber_host_cache, fiber_id, host)}
        {:reply, {:ok, host}, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:bust_fiber_host_cache, fiber_id}, _from, state) do
    {:reply, :ok, %{state | fiber_host_cache: Map.delete(state.fiber_host_cache, fiber_id)}}
  end

  # Detects fibers that opted out of agent dispatch by setting
  # `shuttle.agent: human`. Used by the API dispatch path to short-circuit
  # with a friendly success and by the poller-side eligibility filter to
  # skip human-worker fibers in the auto-dispatch loop.
  defp human_worker?(fiber) do
    case get_in(fiber, ["shuttle", "agent"]) do
      "human" -> true
      _ -> false
    end
  end

  # ── Snapshot ──

  @spec build_snapshot(State.t()) :: map()
  defp build_snapshot(state) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    eligible =
      Enum.map(state.running, fn {fiber_id, meta} ->
        %{
          fiber_id: fiber_id,
          felt_store: Map.get(state.fiber_host_cache, fiber_id),
          tmux_session: meta.session,
          agent: meta.agent_id,
          state: Map.get(meta, :state, "running"),
          run_id: Map.get(meta, :run_id),
          started_at: DateTime.to_unix(meta.started_at, :millisecond),
          last_activity_at: DateTime.to_unix(meta.last_activity_at, :millisecond),
          runtime_seconds: runtime_seconds(meta.started_at, now)
        }
      end)

    retrying =
      Enum.map(state.retry_queue, fn {fiber_id, retry} ->
        %{
          fiber_id: fiber_id,
          attempt: retry.attempt,
          due_in_ms: max(0, retry.due_at_ms - now_ms),
          error: Map.get(retry, :error)
        }
      end)

    blocked =
      Enum.map(state.dispatch_failures, fn {fiber_id, entry} ->
        %{
          fiber_id: fiber_id,
          reason: format_block_reason(entry.reason),
          attempts: entry.attempts,
          attempted_at: DateTime.to_unix(entry.attempted_at, :millisecond),
          first_attempted_at: DateTime.to_unix(entry.first_attempted_at, :millisecond)
        }
      end)

    %{
      poll_at: now_ms,
      # Reflect the dispatch-filter identity, not just :inet.gethostname().
      # When SHUTTLE_HOST is set this matches the host operators read in logs
      # and use to author `shuttle.host:` pins on fibers.
      host: state.own_host_id,
      felt_stores: state.felt_stores,
      eligible: eligible,
      blocked: blocked,
      orphans: state.orphans,
      retrying: retrying,
      standing_roles: standing_role_snapshots(state.standing_roles, state.running, now),
      claimed_count: MapSet.size(state.claimed),
      max_concurrent: state.max_concurrent_workers
    }
  end

  # Stringifies dispatch-failure reasons for the snapshot. Atoms become their
  # name (':missing_session_id' is more useful in the UI than the raw atom);
  # strings pass through; everything else falls back to inspect/1.
  defp format_block_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_block_reason(reason) when is_binary(reason), do: reason
  defp format_block_reason(reason), do: inspect(reason)

  defp broadcast_snapshot(state) do
    snap = build_snapshot(state)
    Phoenix.PubSub.broadcast(Shuttle.PubSub, @pubsub_topic, {:snapshot, snap})
    snap
  end

  # ── Dispatch ──

  defp maybe_dispatch(%State{} = state) do
    state = state |> refresh_felt_stores() |> reconcile()
    {:ok, candidates, new_host_map} = discover_candidates(state)

    # Merge newly resolved host entries into the cache. Existing entries
    # are not evicted — earlier-configured hosts win for ID collisions,
    # and cache entries are stable for the daemon's lifetime.
    state = %{
      state
      | fiber_host_cache: Map.merge(new_host_map, state.fiber_host_cache),
        standing_roles: standing_roles_from_candidates(candidates),
        dispatch_failures: evict_stale_dispatch_failures(state.dispatch_failures, candidates)
    }

    # Resurrect orphaned dispatched fibers — workers whose tmux sessions
    # exited while the daemon was down (or otherwise not watching) so the
    # worker_exited path never fired. Runs unconditionally on slots so
    # orphans get back into the retry queue even when the dispatch budget
    # is exhausted; the retry timer waits for capacity.
    state = reconcile_dispatched_dead_fibers(state, candidates)

    if available_slots(state) > 0 do
      dispatchable = candidates |> filter_eligible(state) |> sort_candidates()

      Enum.reduce(dispatchable, state, fn fiber, state_acc ->
        if available_slots(state_acc) > 0 do
          {new_state, _result} = do_dispatch_fiber(state_acc, fiber)
          new_state
        else
          state_acc
        end
      end)
    else
      state
    end
  end

  # ── Orphan Resurrection ──

  # Detect fibers that were dispatched at least once (shuttle.session.id set)
  # but whose tmux sessions are no longer alive AND aren't being tracked by a
  # WorkerWatcher. This happens when the worker exits while the daemon is down
  # — `worker_watcher` never fires `worker_exited`, the continuation retry
  # never schedules, and the fiber sits forever in a "dispatched but dead"
  # limbo. Without this pass the human ends up with a kanban card that says
  # in-flight for a session that ended hours ago.
  #
  # `adopt_orphans` (init) and `reconcile_orphaned_sessions` (per-poll) handle
  # the *live* analog: a tmux session exists, we just aren't watching it.
  # This pass is the *dead* analog: no tmux session, but the fiber thinks it
  # was dispatched. Mirrors what `handle_worker_exit` would have done if the
  # daemon had been up.
  #
  # Standing roles are excluded: they use `review.state` for lifecycle, not
  # session.id presence. A standing role's session.id is the historical
  # marker for the most recent run, not a signal that a worker should still
  # be running now.
  defp reconcile_dispatched_dead_fibers(%State{} = state, candidates) do
    # list_shuttle_sessions returns {:ok, []} on tmux-server-absent today (never
    # errors), so this match is total; if it ever grows an error tuple, the
    # compiler will surface the missing clause.
    {:ok, sessions} = list_shuttle_sessions(state)
    live = MapSet.new(sessions)

    Enum.reduce(candidates, state, fn fiber, acc ->
      maybe_resurrect_orphan(acc, fiber, live)
    end)
  end

  defp maybe_resurrect_orphan(%State{} = state, fiber, live_sessions) do
    fiber_id = Map.get(fiber, "id", "")
    shuttle = Map.get(fiber, "shuttle", %{})
    status = Map.get(fiber, "status", "")
    kind = Map.get(shuttle, "kind", Map.get(shuttle, "mode", "oneshot"))

    session_id =
      case Map.get(shuttle, "session", %{}) do
        %{"id" => id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    cond do
      # Only the owning daemon may resurrect. A fiber owned by another host
      # (or unowned — absent host:) is not this daemon's orphan; leave it for
      # the owning daemon or the kanban. This is the load-bearing gate: a
      # remote restart must never re-grab a Mac-owned fiber whose loom-synced
      # block still carries a stale session UUID (the 2026-05-30 incident).
      not host_owned?(shuttle, state.own_host_id) ->
        state

      # A declared project_dir absent on this host disqualifies resurrection
      # too — same rule as the poll path.
      not project_dir_available?(shuttle) ->
        state

      # Standing roles use review.state, not session.id, for lifecycle.
      kind == "standing" ->
        state

      # Never dispatched — nothing to resurrect.
      session_id == nil ->
        state

      # Closed — work is done.
      status == "closed" ->
        state

      # Already tracking (a WorkerWatcher is alive for this fiber).
      Map.has_key?(state.running, fiber_id) ->
        state

      # Retry already queued.
      MapSet.member?(state.claimed, fiber_id) ->
        state

      # tmux session for this fiber is live — `adopt_orphans` /
      # `reconcile_orphaned_sessions` will pick it up; not our problem.
      MapSet.member?(live_sessions, Dispatcher.session_name(fiber_id)) ->
        state

      true ->
        Logger.info(
          "Resurrecting orphan dispatch: fiber_id=#{fiber_id} " <>
            "session_id=#{session_id} — worker exited while daemon was down " <>
            "or unwatched; scheduling continuation retry"
        )

        attempt = next_retry_attempt(state, fiber_id)

        schedule_retry(state, fiber_id, attempt, %{
          delay_type: :continuation,
          reason: :orphan_resurrected
        })
    end
  end

  # Drops dispatch_failures entries for fibers shuttle no longer intends to
  # dispatch — closed, paused (status not in {open, active}), shuttle block
  # removed, or absent from the felt store entirely. Without this, the
  # `blocked` snapshot would carry stale entries the user has no remaining
  # handle on. Active fibers with persistent failures keep their entry
  # across cycles so the kanban can show the failure count.
  defp evict_stale_dispatch_failures(failures, candidates) do
    active_ids =
      candidates
      |> Enum.filter(fn fiber -> Map.get(fiber, "status") in ["open", "active"] end)
      |> Enum.map(&Map.get(&1, "id", ""))
      |> MapSet.new()

    Map.filter(failures, fn {fiber_id, _entry} -> MapSet.member?(active_ids, fiber_id) end)
  end

  defp run_poll_cycle_safely(%State{} = state) do
    {:ok, maybe_dispatch(state)}
  rescue
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp merge_poll_cycle_state(%State{} = current, %State{} = poll_state) do
    running = merge_running_state(current.running, poll_state.running, poll_state.orphans)

    retry_queue =
      poll_state.retry_queue
      |> Map.merge(current.retry_queue)
      |> Map.drop(Map.keys(running))

    %{
      poll_state
      | running: running,
        claimed: claimed_from(running, retry_queue),
        retry_queue: retry_queue,
        waiters: current.waiters,
        reservations: current.reservations,
        completed_standing_runs:
          MapSet.union(poll_state.completed_standing_runs, current.completed_standing_runs),
        standing_roles: poll_state.standing_roles,
        orphans: poll_state.orphans,
        # Carry the poll cycle's view. Sync :dispatch calls that ran in
        # parallel with the poll Task lose their dispatch_failures updates;
        # they'll re-record on the next attempt. The alternative — merging
        # both — keeps stale entries when the poll evicts a fiber that just
        # finished a sync dispatch from outside.
        dispatch_failures: poll_state.dispatch_failures
    }
  end

  defp merge_running_state(current_running, poll_running, poll_orphans) do
    stale_sessions =
      MapSet.new(
        Enum.map(poll_orphans, fn orphan ->
          {Map.get(orphan, :fiber_id), Map.get(orphan, :tmux_session)}
        end)
      )

    current_running
    |> Enum.reject(fn {fiber_id, meta} ->
      MapSet.member?(stale_sessions, {fiber_id, Map.get(meta, :session)})
    end)
    |> Map.new()
    |> then(&Map.merge(poll_running, &1))
  end

  defp claimed_from(running, retry_queue) do
    running
    |> Map.keys()
    |> Enum.concat(Map.keys(retry_queue))
    |> MapSet.new()
  end

  # Discovers candidate fibers by walking <host>/.felt/ for files that carry a
  # shuttle: frontmatter block. No tag predicate — the block is the source of
  # truth, matching the same shuttle-block contract every other surface reads.
  #
  # Returns {:ok, fibers, host_map} where:
  #   fibers   — [%{"id" => id, "status" => status}] across all hosts
  #   host_map — %{fiber_id => felt_store} for host resolution
  #
  # ## Symlink discipline
  #
  # The same physical fiber file is often reachable from multiple felt
  # hosts via symlinks. Two cases that occur in practice:
  #
  # 1. A project host (`~/work/project-a`) whose `.felt/` is a symlink into
  #    `~/loom/.felt/work/project-a/`. The same `task-board.md` is reachable
  #    as `task-board` (project view) and `work/project-a/task-board`
  #    (loom view).
  #
  # 2. A project-canonical felt store (lightcone) whose own `.felt/` is a
  #    real directory, with loom symlinking *into* it at
  #    `~/loom/.felt/ai-futures/lightcone -> ~/lightcone/.felt`. The same
  #    fiber is reachable as `lightcone-ui/...` (lightcone view) and
  #    `ai-futures/lightcone/lightcone-ui/...` (loom view).
  #
  # If we enumerate both views, dispatch races: each "different" id passes
  # `tmux has-session` independently → multiple workers on the same file.
  # Worse, the wrong host may win — loom's `index.db` doesn't contain the
  # lightcone fiber under the loom-relative id, so `felt -C ~/loom show
  # ai-futures/lightcone/...` fails and dispatch silently never happens.
  #
  # **Rule: a fiber should be enumerated only by the host where it is
  # physically rooted** — i.e. reachable from `<host>/.felt/` without
  # traversing any symlinks. We enforce this two ways:
  #
  # - `owned_fiber_ids/1` skips the host entirely if `<host>/.felt/`
  #   itself is a symlink (case 1: project-cities-on-loom).
  #
  # - `do_walk_felt_dir/1` skips subdirectories that are symlinks (case 2:
  #   loom symlinking into a project-canonical host).
  #
  # Once we know which IDs are physically rooted in a host, felt becomes the
  # sole reader: `list_shuttle_fibers/3` shells out once per host to a narrow
  # `felt ls --json --has-field shuttle --json-field ...` projection, then
  # filters that JSON payload down to the owned IDs that actually carry a
  # `shuttle:` block.
  #
  # The `file_identity` MapSet below is belt-and-suspenders for esoteric
  # cases (hard links, etc.) where two physically-distinct paths point at
  # the same inode and both pass the symlink filter.
  defp discover_candidates(state) do
    {all_fibers, host_map} =
      Enum.reduce(state.felt_stores, {[], %{}}, fn host, {acc_fibers, acc_map} ->
        owned_ids = owned_fiber_ids(host)

        case list_shuttle_fibers(host, owned_ids, state) do
          {:ok, fibers} ->
            new_map =
              Enum.reduce(fibers, %{}, fn fiber, hm ->
                id = Map.get(fiber, "id", "")
                Map.put(hm, id, host)
              end)

            merged_map = Map.merge(new_map, acc_map)
            {acc_fibers ++ fibers, merged_map}

          {:error, _} ->
            {acc_fibers, acc_map}
        end
      end)

    {:ok, all_fibers, host_map}
  end

  # Walk <host>/.felt/ and return the set of fiber IDs physically rooted in
  # this host (no symlink traversal). Skips the host entirely if
  # `<host>/.felt/` is itself a symlink.
  defp owned_fiber_ids(host) do
    felt_dir = Path.join(host, ".felt")
    canonical_host = canonical_host_path(host)

    case File.lstat(felt_dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        # Host's .felt/ is a symlink — its content is owned by the host
        # where .felt is physically rooted. That host enumerates canonically.
        MapSet.new()

      _ ->
        felt_dir
        |> do_walk_felt_dir()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reduce({MapSet.new(), MapSet.new()}, fn path, {ids, seen} ->
          ident = file_identity(path)

          cond do
            ident != nil and MapSet.member?(seen, ident) ->
              {ids, seen}

            true ->
              next_seen = if ident, do: MapSet.put(seen, ident), else: seen

              case fiber_ref_from_path(path) do
                {:ok, %{host: ^canonical_host, id: fiber_id}} ->
                  {MapSet.put(ids, fiber_id), next_seen}

                _ ->
                  {ids, next_seen}
              end
          end
        end)
        |> elem(0)
    end
  end

  # Read one host's candidate fibers via felt's JSON output, then keep only
  # physically-rooted IDs with a shuttle block. Felt is the canonical reader;
  # the filesystem walk above only determines ownership across hosts.
  defp list_shuttle_fibers(host, owned_ids, state) do
    if MapSet.size(owned_ids) == 0 do
      {:ok, []}
    else
      case run_felt_ls_for_shuttle(host, state) do
        {:ok, output} ->
          with {:ok, fibers} when is_list(fibers) <- Jason.decode(output) do
            kept =
              Enum.filter(fibers, fn fiber ->
                id = Map.get(fiber, "id", "")
                MapSet.member?(owned_ids, id) and is_map(Map.get(fiber, "shuttle"))
              end)

            {:ok, kept}
          else
            _ -> {:error, :invalid_json}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_felt_ls_for_shuttle(host, state) do
    projected_args = [
      "ls",
      "--json",
      "--has-field",
      "shuttle",
      "--json-field",
      @felt_shuttle_projection_fields
    ]

    case run_felt(host, state.runner, projected_args) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} ->
        Logger.warning(
          "projected felt ls failed for #{host}; falling back to legacy broad listing: #{inspect(reason)}"
        )

        run_felt(host, state.runner, ["ls", "--json"])
    end
  end

  # `(major_device, inode)` from `File.stat` (follows symlinks) uniquely
  # identifies a physical file regardless of which symlink path you used
  # to reach it. Returns nil on stat failure so the caller can fall back
  # to keeping the entry un-deduped.
  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %File.Stat{major_device: dev, inode: inode}} -> {dev, inode}
      {:error, _} -> nil
    end
  end

  defp do_walk_felt_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          # `lstat` (does NOT follow symlinks) lets us distinguish symlinked
          # directories from physical ones. We never traverse a symlink — the
          # host where the target is physically rooted enumerates it instead
          # (see the symlink-discipline note on `discover_candidates/1`).
          case File.lstat(path) do
            {:ok, %File.Stat{type: :symlink}} ->
              []

            {:ok, %File.Stat{type: :directory}} ->
              if String.starts_with?(entry, ".") do
                # Hidden subdirectories (e.g. .obsidian) — skip.
                []
              else
                do_walk_felt_dir(path)
              end

            {:ok, _} ->
              [path]

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Canonical `(host, id)` for an on-disk fiber path. The store boundary is the
  # nearest real `.felt/` directory, so symlinked project views collapse back to
  # Shuttle's dispatch identity (e.g. loom for portolan fibers, lightcone for
  # project-canonical fibers).
  defp fiber_ref_from_path(path) do
    resolved =
      case resolve_realpath(path) do
        {:ok, real} -> real
        {:error, _} -> Path.expand(path)
      end

    segments = Path.split(resolved)

    felt_idx =
      segments
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {".felt", idx}, _acc -> idx
        _, acc -> acc
      end)

    if is_integer(felt_idx) do
      host_parts = Enum.take(segments, felt_idx)
      tail = Enum.drop(segments, felt_idx + 1)

      with {:ok, fiber_id} <- fiber_id_from_tail(tail) do
        host =
          case host_parts do
            [] -> "/"
            parts -> Path.join(parts)
          end

        {:ok, %{host: host, id: fiber_id}}
      end
    else
      {:error, :no_felt_store}
    end
  end

  defp fiber_id_from_tail([]), do: {:error, :empty_tail}

  defp fiber_id_from_tail([file]) do
    if String.ends_with?(file, ".md") do
      {:ok, String.replace_suffix(file, ".md", "")}
    else
      {:error, :not_markdown}
    end
  end

  defp fiber_id_from_tail(tail) do
    file = List.last(tail)
    parent = Enum.at(tail, -2)

    cond do
      not String.ends_with?(file, ".md") ->
        {:error, :not_markdown}

      String.replace_suffix(file, ".md", "") != parent ->
        {:error, :unexpected_layout}

      true ->
        {:ok, tail |> Enum.take(length(tail) - 1) |> Path.join()}
    end
  end

  defp resolve_realpath(path) do
    expanded = Path.expand(path)

    case Path.split(expanded) do
      ["/" | rest] -> resolve_realpath_segments("/", rest, MapSet.new())
      [first | rest] -> resolve_realpath_segments(first, rest, MapSet.new())
      [] -> {:error, :empty_path}
    end
  end

  defp resolve_realpath_segments(current, [], _seen), do: {:ok, current}

  defp resolve_realpath_segments(current, [segment | rest], seen) do
    candidate = Path.join(current, segment)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target_path = List.to_string(target)

        expanded_target =
          case Path.type(target_path) do
            :absolute -> Path.expand(target_path)
            :relative -> Path.expand(target_path, Path.dirname(candidate))
            _ -> Path.expand(target_path, Path.dirname(candidate))
          end

        if MapSet.member?(seen, candidate) do
          {:error, :symlink_loop}
        else
          case Path.split(expanded_target) do
            ["/" | target_rest] ->
              resolve_realpath_segments("/", target_rest ++ rest, MapSet.put(seen, candidate))

            [first | target_rest] ->
              resolve_realpath_segments(first, target_rest ++ rest, MapSet.put(seen, candidate))

            [] ->
              {:error, :empty_target}
          end
        end

      {:error, _} ->
        resolve_realpath_segments(candidate, rest, seen)
    end
  end

  defp canonical_host_path(host) do
    case resolve_realpath(host) do
      {:ok, resolved} -> resolved
      {:error, _} -> Path.expand(host)
    end
  end

  defp exact_fiber_path(host, fiber_id) do
    segments = String.split(fiber_id, "/")
    basename = List.last(segments)
    felt_dir = Path.join(host, ".felt")
    bare_path = Path.join(felt_dir, "#{basename}.md")
    dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])

    cond do
      not String.contains?(fiber_id, "/") and File.exists?(bare_path) ->
        {:ok, bare_path}

      File.exists?(dir_path) ->
        {:ok, dir_path}

      true ->
        {:error, :not_found}
    end
  end

  defp filter_eligible(candidates, state) do
    Enum.filter(candidates, fn fiber -> eligible?(fiber, state) end)
  end

  defp eligible?(fiber, state) do
    status = Map.get(fiber, "status", "")
    fiber_id = Map.get(fiber, "id", "")
    shuttle = Map.get(fiber, "shuttle")

    if is_map(shuttle) do
      cond do
        # Human-worker fibers opt out of auto-dispatch entirely. The user
        # is doing the work themselves; the kanban shows the card in
        # inFlight via status:active + enabled:true, but Shuttle never
        # tries to spawn anything.
        human_worker?(fiber) ->
          false

        # Must have shuttle.enabled: true
        Map.get(shuttle, "enabled", false) != true ->
          false

        # Must target this daemon. Exactly `block.host == own_host_id`; an
        # absent host is unowned and ineligible everywhere (no wildcard, no
        # "local" default).
        not host_owned?(shuttle, state.own_host_id) ->
          false

        # A declared project_dir must exist on this host — disqualify, don't
        # downgrade the worker cwd to a felt store.
        not project_dir_available?(shuttle) ->
          false

        # Must be committed to active work
        status not in ["open", "active"] ->
          false

        # Must not already be running
        Map.has_key?(state.running, fiber_id) ->
          false

        # Must not be claimed (retry queued)
        MapSet.member?(state.claimed, fiber_id) ->
          false

        # Standing roles have additional preconditions; oneshots go to dep check.
        # Support both new-format (kind:) and old-format (mode:) shuttle blocks.
        Map.get(shuttle, "kind", Map.get(shuttle, "mode", "oneshot")) == "standing" ->
          standing_role_due?(fiber_id, state)

        # Dependencies must be satisfied
        true ->
          dependencies_satisfied?(fiber_id, state)
      end
    else
      false
    end
  end

  # Eligibility for an explicit dispatch call (POST /api/v1/dispatch).
  #
  # Three modes, in priority order:
  #
  #   1. `force: true` — manual human-triggered dispatch from the kanban
  #      "New session" / "Resume" buttons. Bypasses every condition except
  #      the ones that *can't* be overridden by intent: a shuttle block must
  #      exist (we need an agent + project_dir to spawn), the host must
  #      match (we can't conjure a worker on the wrong machine), and the
  #      fiber must not be a human-worker (no machine to spawn). Status,
  #      enabled, kind, review_state, schedule, validity, and dependencies
  #      are all overridden. Closed, composted, disabled, not-yet-due, and
  #      unvalidated fibers all dispatch on force.
  #
  #   2. `ad_hoc: true` (without `force`) — legacy manual trigger for
  #      standing roles that bypasses the schedule but still requires the
  #      role to be otherwise dispatchable (enabled, active, valid, in a
  #      scheduleable review state). Kept for callers that still rely on it.
  #
  #   3. Default — full `eligible?` check (status, enabled, schedule,
  #      review state, deps, validity).
  defp dispatch_eligible?(fiber, state, opts) do
    cond do
      Keyword.get(opts, :force, false) ->
        force_dispatch_eligible?(fiber, state)

      Keyword.get(opts, :ad_hoc, false) and force_dispatchable_standing_role?(fiber, state) ->
        dependencies_satisfied?(Map.get(fiber, "id", ""), state)

      true ->
        eligible?(fiber, state)
    end
  end

  # Force-dispatch predicate: only the irreducible requirements. The user
  # explicitly clicked dispatch; honor the intent.
  defp force_dispatch_eligible?(fiber, state) do
    shuttle = Map.get(fiber, "shuttle")

    cond do
      not is_map(shuttle) -> false
      human_worker?(fiber) -> false
      not host_owned?(shuttle, state.own_host_id) -> false
      true -> true
    end
  end

  defp force_dispatchable_standing_role?(fiber, state) do
    status = Map.get(fiber, "status", "")
    fiber_id = Map.get(fiber, "id", "")
    shuttle = Map.get(fiber, "shuttle")

    with true <- is_map(shuttle),
         true <- Map.get(shuttle, "enabled", false) == true,
         true <- host_owned?(shuttle, state.own_host_id),
         true <- status in ["open", "active"],
         {:ok, role} <- fetch_standing_role(fiber_id, state),
         true <- StandingRole.standing?(role),
         true <- StandingRole.valid?(role) do
      review_state = role.review["state"] || "scheduled"
      review_state in ["scheduled", "accepted", "due"]
    else
      _ -> false
    end
  end

  defp awaiting_ad_hoc_dispatch_error(fiber, state, opts) do
    if Keyword.get(opts, :ad_hoc, false) do
      fiber_id = Map.get(fiber, "id", "")

      with {:ok, role} <- fetch_standing_role(fiber_id, state),
           true <- StandingRole.standing?(role),
           review_state when review_state in ["awaiting", "review", "in_review"] <-
             role.review["state"] || "scheduled" do
        {:error,
         {:awaiting_review, Map.get(role.review, "run_id"), Map.get(role.review, "completed_at")}}
      else
        _ -> false
      end
    else
      false
    end
  end

  # THE single host-ownership predicate. A fiber is owned by this daemon when
  # its shuttle block carries an explicit `host:` equal to this daemon's
  # `own_host_id`. There is no `nil`-as-wildcard and no `"local"` default: an
  # absent or empty `host:` is unowned everywhere and therefore ineligible on
  # every daemon — loud (the fiber simply never dispatches and the absence is
  # visible in its frontmatter), never silently mis-dispatched on the wrong
  # machine. Every dispatch path (poll, force, standing, orphan-resurrection)
  # routes through this one function.
  #
  # Three pre-cutover failure modes this collapses:
  #   - `(block.host || "local")` default → host-less fibers matched the
  #     literal "local" daemon (which no real daemon advertised) → ineligible
  #     everywhere, silently.
  #   - `nil`-pin-as-wildcard → host-less fibers matched *every* daemon → the
  #     wrong machine grabbed single-host work.
  # Strict equality removes both: a block is owned by exactly one named host.
  defp host_owned?(shuttle, own_host_id) when is_map(shuttle) do
    case Map.get(shuttle, "host") do
      host when is_binary(host) and host != "" -> host == own_host_id
      _ -> false
    end
  end

  defp host_owned?(_, _), do: false

  # A declared `project_dir` must exist on THIS host. Present-but-missing means
  # the fiber's checkout lives on another machine — disqualify here rather than
  # silently downgrading the worker cwd to a felt store (the native-desktop
  # misdispatch root cause #2). This *disqualifies, does not downgrade*. An
  # absent/empty project_dir is governed by install-time schema validation
  # (enabled blocks must carry one), not re-litigated at every poll.
  defp project_dir_available?(shuttle) when is_map(shuttle) do
    case Map.get(shuttle, "project_dir") do
      dir when is_binary(dir) and dir != "" -> File.dir?(Path.expand(dir))
      _ -> true
    end
  end

  defp project_dir_available?(_), do: true

  @doc """
  Resolves this daemon's `own_host_id` — the identity it advertises for the
  `shuttle.host` dispatch filter. Public so other callers (e.g.
  `ShuttleWeb.FiberController` when stamping a `host:` on a new fiber) share
  the exact same resolution.

  Precedence:

    1. `SHUTTLE_HOST` env var, if set and non-empty. Operators override here
       when they want a friendly name distinct from `:inet.gethostname()`
       (e.g. `SHUTTLE_HOST=mac` instead of `dapmcw68`, or `candide` instead
       of `c03`). Also the seam for tests / smoke harnesses that need a
       stable identity — `config/test.exs` calls `System.put_env/2` to pin
       a value at test boot.

    2. `:inet.gethostname()` — short OS hostname. Two separately-deployed
       daemons get distinct ids automatically; no per-machine config needed.

  No `Application.get_env(:shuttle, :host)` step. An earlier iteration
  pinned `host: "local"` in `config/test.exs` so tests had a predictable
  identity, but the pin leaked into escripts built with `MIX_ENV=test` and
  stamped `"local"` onto production daemons — every fiber without an
  explicit `host:` then silently failed the dispatch filter (which used to
  default to `"local"` too). The whole `"local"` magic is gone.

  Raises if `:inet.gethostname/0` truly fails. That's a system-level
  problem and silently degrading into a no-op filter (what the previous
  `"local"` fallback did) made the failure invisible.
  """
  @spec own_host_id() :: String.t()
  def own_host_id do
    case System.get_env("SHUTTLE_HOST") do
      env when is_binary(env) and env != "" ->
        env

      _ ->
        case :inet.gethostname() do
          {:ok, name} when name != [] ->
            to_string(name)

          other ->
            raise "Shuttle.Poller could not resolve own_host_id: " <>
                    ":inet.gethostname/0 returned #{inspect(other)}. " <>
                    "Set SHUTTLE_HOST=<name> in the daemon environment."
        end
    end
  end

  # Internal alias used by the Poller's own startup. Kept for callsite
  # readability — `resolve_own_host_id()` reads naturally inside the
  # init/handle_call code.
  defp resolve_own_host_id, do: own_host_id()

  defp standing_roles_from_candidates(candidates) do
    Enum.flat_map(candidates, fn fiber ->
      case standing_role_from_fiber(fiber) do
        {:ok, role} ->
          if StandingRole.standing?(role), do: [role], else: []

        {:error, _} ->
          []
      end
    end)
  end

  defp standing_role_from_fiber(fiber) do
    fiber_id = Map.get(fiber, "id", "")

    case Map.get(fiber, "shuttle") do
      shuttle when is_map(shuttle) -> StandingRole.from_map(fiber_id, shuttle)
      _ -> {:error, :no_shuttle_block}
    end
  end

  # Resolves which configured felt store owns `fiber_id`.
  #
  # Resolution order:
  # 1. State cache (fast; populated by discover_candidates/1 each poll cycle)
  # 2. Exact-path probe across each configured host, followed by canonical-store
  #    validation so symlinked project views do not claim loom-owned fibers.
  #
  # Returns {:ok, host} for the first-configured host that canonically owns the
  # fiber, or {:error, :not_found} when no host claims it.
  #
  # Cache updates are the caller's responsibility (discover_candidates/1 does
  # it for the whole poll cycle; handle_call(:resolve_fiber_host) returns the
  # result without caching since it can't mutate state on the reply path without
  # a cast).
  defp host_for_fiber(fiber_id, state) do
    case Map.get(state.fiber_host_cache, fiber_id) do
      host when is_binary(host) ->
        {:ok, host}

      nil ->
        found =
          Enum.find_value(state.felt_stores, fn host ->
            canonical_host = canonical_host_path(host)

            with {:ok, path} <- exact_fiber_path(host, fiber_id),
                 {:ok, %{host: ^canonical_host, id: ^fiber_id}} <- fiber_ref_from_path(path) do
              host
            else
              _ -> nil
            end
          end)

        case found do
          nil -> {:error, :not_found}
          host -> {:ok, host}
        end
    end
  end

  # Read a fiber through felt's JSON view and extract the shuttle block.
  # Felt remains the canonical reader; callers that only need shuttle-owned
  # fields route through this helper rather than reparsing frontmatter.
  defp fetch_shuttle_block(fiber_id, state) do
    with {:ok, fiber} <- fetch_fiber_full(fiber_id, state),
         shuttle when is_map(shuttle) <- Map.get(fiber, "shuttle") do
      {:ok, shuttle}
    else
      _ -> {:error, :no_shuttle_block}
    end
  end

  # Extract the shuttle.agent name from a pre-fetched shuttle block map.
  # Returns nil when absent (the caller should use the default agent).
  defp shuttle_agent_from_block(shuttle) when is_map(shuttle) do
    case Map.get(shuttle, "agent") do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp shuttle_agent_from_block(_), do: nil

  # Returns the shuttle.agent name for a fiber, reading its block through felt.
  # Used by dispatch paths that don't already hold the block map.
  defp fetch_shuttle_agent_name(fiber_id, state) do
    case fetch_shuttle_block(fiber_id, state) do
      {:ok, shuttle} -> shuttle_agent_from_block(shuttle)
      {:error, _} -> nil
    end
  end

  # Returns the working directory to use when dispatching this fiber.
  #
  # When the fiber's shuttle block contains a `project_dir` key pointing to an
  # existing directory, that directory is used as the tmux session's starting
  # directory. This lets workers load the project's CLAUDE.md (read at session
  # start from CWD upwards) rather than always starting in the loom root.
  #
  # Tilde-prefixed paths are expanded. Falls back to the fiber's resolved felt
  # host (or the first configured host if resolution fails) when `project_dir`
  # is absent, empty, or does not exist on disk.
  defp fiber_work_dir(fiber_id, state) do
    fallback_host =
      case host_for_fiber(fiber_id, state) do
        {:ok, h} -> h
        {:error, _} -> hd(state.felt_stores)
      end

    with {:ok, shuttle} <- fetch_shuttle_block(fiber_id, state),
         dir when is_binary(dir) and dir != "" <- Map.get(shuttle, "project_dir"),
         expanded = Path.expand(dir),
         true <- File.dir?(expanded) do
      expanded
    else
      _ -> fallback_host
    end
  end

  defp dependencies_satisfied?(fiber_id, state) do
    case fetch_fiber_full(fiber_id, state) do
      {:ok, full_fiber} ->
        deps = Map.get(full_fiber, "depends_on", [])

        if deps == [] or is_nil(deps) do
          true
        else
          Enum.all?(deps, fn dep ->
            case dep_id(dep) do
              nil ->
                false

              dep_id ->
                case fetch_fiber_full(dep_id, state) do
                  {:ok, dep} -> Map.get(dep, "tempered", false) == true
                  {:error, _} -> false
                end
            end
          end)
        end

      {:error, _} ->
        false
    end
  end

  defp dep_id(dep) when is_binary(dep), do: dep
  defp dep_id(%{"id" => id}) when is_binary(id), do: id
  defp dep_id(%{id: id}) when is_binary(id), do: id
  defp dep_id(_), do: nil

  defp sort_candidates(candidates) do
    Enum.sort_by(candidates, fn fiber ->
      created = Map.get(fiber, "created_at", "")
      {created, Map.get(fiber, "id", "")}
    end)
  end

  defp do_dispatch_fiber(%State{} = state, fiber, opts \\ []) do
    fiber_id = Map.get(fiber, "id", "")

    felt_store =
      case host_for_fiber(fiber_id, state) do
        {:ok, h} -> h
        {:error, _} -> hd(state.felt_stores)
      end

    prompt_context = dispatch_prompt_context(fiber, state, opts)

    case Dispatcher.dispatch(
           fiber_id,
           runner: state.runner,
           work_dir: fiber_work_dir(fiber_id, state),
           prompt_context: prompt_context,
           felt_store: felt_store,
           force_fresh: Keyword.get(opts, :force_fresh, false),
           force: Keyword.get(opts, :force, false)
         ) do
      {:ok, :human_no_op} ->
        # Human-worker fibers don't need a watcher or running-state entry —
        # the user is doing the work themselves. Return state unchanged so
        # the kanban shows the card in inFlight (status:active, enabled:true)
        # without any tmux session to watch.
        Logger.info("Human-worker fiber #{fiber_id} accepted; no watcher started")
        {state, {:ok, "human"}}

      {:ok, session} ->
        agent_name = fetch_shuttle_agent_name(fiber_id, state)
        {:ok, agent} = Shuttle.Agents.resolve_by_name(agent_name)

        now = DateTime.utc_now()

        running_meta =
          %{
            session: session,
            agent_id: agent.id,
            started_at: now,
            last_activity_at: now
          }
          |> Map.merge(running_prompt_metadata(prompt_context))

        case start_watcher(state, fiber_id, running_meta) do
          {:ok, running_meta} ->
            running = Map.put(state.running, fiber_id, running_meta)
            persist_running(state, fiber_id, running_meta)

            state = %{
              state
              | running: running,
                claimed: MapSet.put(state.claimed, fiber_id),
                dispatch_failures: Map.delete(state.dispatch_failures, fiber_id)
            }

            broadcast_snapshot(state)
            {state, {:ok, session}}

          {:error, reason} ->
            Logger.error("Failed to start watcher for #{fiber_id}: #{inspect(reason)}")

            state =
              schedule_retry(state, fiber_id, 1, %{
                error: "watcher start failed: #{inspect(reason)}"
              })

            state = record_dispatch_failure(state, fiber_id, :watcher_start_failed)
            {state, {:error, :watcher_start_failed}}
        end

      {:error, :already_running} ->
        # Session exists but we don't have a watcher — adopt it
        state = adopt_session(state, fiber_id)
        state = %{state | dispatch_failures: Map.delete(state.dispatch_failures, fiber_id)}
        {state, {:error, :already_running}}

      {:error, reason} ->
        Logger.warning("Dispatch failed for #{fiber_id}: #{inspect(reason)}")
        state = record_dispatch_failure(state, fiber_id, reason)
        {state, {:error, reason}}
    end
  end

  # Records (or refreshes the attempt count on) a dispatch failure. The map
  # entry is surfaced in `build_snapshot/1` under `blocked` so the kanban can
  # show why a fiber is stuck — replacing the silent-warning-log failure mode
  # where a `:missing_session_id` block could persist for days unnoticed.
  defp record_dispatch_failure(%State{} = state, fiber_id, reason) do
    now = DateTime.utc_now()

    entry =
      case Map.get(state.dispatch_failures, fiber_id) do
        %{reason: ^reason, attempts: n} = e ->
          %{e | attempts: n + 1, attempted_at: now}

        _ ->
          %{reason: reason, attempts: 1, attempted_at: now, first_attempted_at: now}
      end

    %{state | dispatch_failures: Map.put(state.dispatch_failures, fiber_id, entry)}
  end

  # ── Reconciliation ──

  defp reconcile(%State{} = state) do
    state = %{state | orphans: []}
    state = reconcile_fiber_closures(state)
    state = reconcile_missing_running_sessions(state)
    state = reconcile_orphaned_sessions(state)
    state = reconcile_waiters(state)
    state = clean_expired_reservations(state)
    state
  end

  defp reconcile_fiber_closures(%State{running: running} = state) when map_size(running) == 0 do
    state
  end

  defp reconcile_fiber_closures(%State{} = state) do
    Enum.reduce(state.running, state, fn {fiber_id, meta}, state_acc ->
      case fetch_fiber_full(fiber_id, state_acc) do
        {:ok, fiber} ->
          if Map.get(fiber, "status") == "closed" do
            Logger.info("Fiber closed externally: #{fiber_id}; stopping watcher")
            stop_watcher(meta)
            remove_running(state_acc, fiber_id)
          else
            state_acc
          end

        {:error, _} ->
          state_acc
      end
    end)
  end

  defp reconcile_orphaned_sessions(%State{} = state) do
    # Find tmux sessions that exist but have no watcher.
    {:ok, sessions} = list_shuttle_sessions(state)
    running_sessions = Enum.map(state.running, fn {_, meta} -> meta.session end) |> MapSet.new()

    orphan_sessions = Enum.reject(sessions, &MapSet.member?(running_sessions, &1))

    if orphan_sessions == [] do
      state
    else
      lookup = candidate_session_lookup(state)

      Enum.reduce(orphan_sessions, state, fn session, state_acc ->
        adopt_known_orphan_session(state_acc, lookup, session)
      end)
    end
  end

  defp reconcile_missing_running_sessions(%State{running: running} = state)
       when map_size(running) == 0 do
    state
  end

  defp reconcile_missing_running_sessions(%State{} = state) do
    Enum.reduce(state.running, state, fn {fiber_id, %{session: session} = meta}, state_acc ->
      if already_running_session?(state_acc, session) do
        state_acc
      else
        Logger.info("Detected missing worker session: #{fiber_id} session=#{session}")
        stop_watcher(meta)

        state_acc
        |> record_orphaned_running_worker(fiber_id, meta)
        |> remove_running(fiber_id)
      end
    end)
  end

  defp record_orphaned_running_worker(%State{} = state, fiber_id, meta) do
    orphan = %{
      fiber_id: fiber_id,
      tmux_session: Map.get(meta, :session),
      agent: Map.get(meta, :agent_id),
      reason: "missing_tmux_session",
      detected_at: DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    }

    %{state | orphans: [orphan | state.orphans]}
  end

  defp rehydrate_runtime_store(%State{} = state) do
    state.runtime_store_path
    |> RuntimeStore.list_running()
    |> Enum.reduce(state, fn %{fiber_id: fiber_id, metadata: metadata}, state_acc ->
      rehydrate_running_record(state_acc, fiber_id, metadata)
    end)
  end

  defp rehydrate_retry_queue(%State{} = state) do
    state.runtime_store_path
    |> RuntimeStore.list_retries()
    |> Enum.reduce(state, fn %{fiber_id: fiber_id, metadata: metadata}, state_acc ->
      rehydrate_retry_record(state_acc, fiber_id, metadata)
    end)
  end

  defp rehydrate_retry_record(%State{} = state, fiber_id, metadata) do
    cond do
      Map.has_key?(state.running, fiber_id) ->
        delete_persisted_retry(state, fiber_id)

      Map.has_key?(state.retry_queue, fiber_id) ->
        state

      true ->
        attempt = Map.get(metadata, :attempt, 1)

        due_at_ms =
          Map.get(metadata, :due_at_ms, DateTime.to_unix(DateTime.utc_now(), :millisecond))

        delay_ms = max(0, due_at_ms - DateTime.to_unix(DateTime.utc_now(), :millisecond))
        retry_token = make_ref()
        timer_ref = Process.send_after(state.self_ref, {:retry, fiber_id, retry_token}, delay_ms)

        retry = %{
          attempt: attempt,
          timer_ref: timer_ref,
          retry_token: retry_token,
          due_at_ms: due_at_ms,
          error: Map.get(metadata, :error),
          delay_type: Map.get(metadata, :delay_type, :failure)
        }

        Logger.info(
          "Rehydrated retry: fiber_id=#{fiber_id} in #{delay_ms}ms (attempt #{attempt})"
        )

        %{
          state
          | retry_queue: Map.put(state.retry_queue, fiber_id, retry),
            claimed: MapSet.put(state.claimed, fiber_id)
        }
    end
  end

  defp rehydrate_running_record(%State{} = state, fiber_id, metadata) do
    session = Map.get(metadata, :session, Dispatcher.session_name(fiber_id))

    cond do
      Map.has_key?(state.running, fiber_id) ->
        state

      not already_running_session?(state, session) ->
        Logger.info(
          "Runtime store record has no live tmux session: #{fiber_id} session=#{session}"
        )

        state
        |> record_orphaned_running_worker(fiber_id, metadata)
        |> delete_persisted_running(fiber_id)

      true ->
        case fetch_fiber_full(fiber_id, state) do
          {:ok, fiber} ->
            if Map.get(fiber, "status") == "closed" do
              Logger.info(
                "Runtime store record is closed in felt; killing stale session: #{session}"
              )

              _ =
                state.runner.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)

              delete_persisted_running(state, fiber_id)
            else
              case start_watcher(state, fiber_id, metadata) do
                {:ok, running_meta} ->
                  Logger.info("Rehydrated runtime worker: #{fiber_id} session=#{session}")

                  %{
                    state
                    | running: Map.put(state.running, fiber_id, running_meta),
                      claimed: MapSet.put(state.claimed, fiber_id)
                  }

                {:error, reason} ->
                  Logger.warning("Failed to rehydrate #{session}: #{inspect(reason)}")
                  state
              end
            end

          {:error, _} ->
            Logger.debug("Runtime store record points at unknown fiber: #{fiber_id}")
            delete_persisted_running(state, fiber_id)
        end
    end
  end

  defp adopt_orphans(%State{} = state) do
    {:ok, sessions} = list_shuttle_sessions(state)
    lookup = candidate_session_lookup(state)

    Enum.reduce(sessions, state, fn session, state_acc ->
      adopt_known_orphan_session(state_acc, lookup, session)
    end)
  end

  defp adopt_session(state, fiber_id) do
    session = Dispatcher.session_name(fiber_id)

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        if Map.get(fiber, "status") != "closed" do
          agent_name = fetch_shuttle_agent_name(fiber_id, state)
          {:ok, agent} = Shuttle.Agents.resolve_by_name(agent_name)

          now = DateTime.utc_now()

          running_meta = %{
            session: session,
            agent_id: agent.id,
            started_at: now,
            last_activity_at: now
          }

          case start_watcher(state, fiber_id, running_meta) do
            {:ok, running_meta} ->
              running = Map.put(state.running, fiber_id, running_meta)
              persist_running(state, fiber_id, running_meta)

              Logger.info("Adopted orphan session: #{session}")
              %{state | running: running, claimed: MapSet.put(state.claimed, fiber_id)}

            {:error, reason} ->
              Logger.warning("Failed to adopt session #{session}: #{inspect(reason)}")
              state
          end
        else
          # Fiber is closed but tmux session still exists — kill it
          Logger.info("Killing stale session for closed fiber: #{session}")
          _ = state.runner.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
          state
        end

      {:error, _} ->
        # Fiber not found — skip, don't kill (could be from another host or test)
        Logger.debug("Skipping orphan session for unknown fiber: #{session}")
        state
    end
  end

  # ── Worker Exit Handling ──

  defp handle_worker_exit(%State{} = state, fiber_id, reason, _session_alive?) do
    # Notify any channel subscribers watching this worker
    Phoenix.PubSub.broadcast(
      Shuttle.PubSub,
      "shuttle:worker:#{fiber_id}",
      {:worker_exited, fiber_id, reason}
    )

    case Map.pop(state.running, fiber_id) do
      {nil, _} ->
        state

      {meta, running} ->
        state = %{state | running: running}

        # Re-read fiber to determine next action
        case fetch_fiber_full(fiber_id, state) do
          {:ok, fiber} ->
            # Auto-log the worker exit to felt history with the session UUID,
            # so users can browse history and find sessions to reattach or
            # diagnose. Best-effort: failure to write history doesn't block
            # the exit-handling state machine. Captured every exit path
            # (clean kill, crash, abort, ghost cleanup) since we always
            # come through here when the daemon notices the session ended.
            log_worker_exit(fiber_id, fiber, meta, reason, state)

            status = Map.get(fiber, "status", "")

            cond do
              status == "closed" ->
                # Work complete or blocked — release claim
                release_claim(state, fiber_id)

              standing_role?(fiber, state) ->
                state
                |> remember_completed_standing_run(fiber_id, Map.get(meta, :run_id))
                |> release_claim(fiber_id)

              true ->
                # Still active — schedule continuation retry
                attempt = next_retry_attempt(state, fiber_id)
                schedule_retry(state, fiber_id, attempt, %{delay_type: :continuation})
            end

          {:error, _} ->
            # Can't read fiber — schedule failure retry
            attempt = next_retry_attempt(state, fiber_id)
            schedule_retry(state, fiber_id, attempt, %{error: "fiber read failed after exit"})
        end
    end
  end

  # ── Retry ──

  defp reconcile_running_fiber(%State{} = state, fiber_id) do
    case Map.get(state.running, fiber_id) do
      nil ->
        state

      %{session: session} = meta ->
        if already_running_session?(state, session) do
          state
        else
          Logger.info("Clearing stale running worker: #{fiber_id} session=#{session}")
          stop_watcher(meta)
          remove_running(state, fiber_id)
        end
    end
  end

  defp handle_retry(%State{} = state, fiber_id, retry) do
    state = release_claim(state, fiber_id)

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        state =
          if eligible?(fiber, state) do
            opts =
              if Map.get(retry, :delay_type) == :continuation do
                [force_fresh: true]
              else
                []
              end

            {new_state, _result} = do_dispatch_fiber(state, fiber, opts)
            new_state
          else
            Logger.debug("Retry no longer eligible: #{fiber_id}")
            release_claim(state, fiber_id)
          end

        {:noreply, state}

      {:error, _} ->
        Logger.debug("Retry fiber not found: #{fiber_id}")
        {:noreply, release_claim(state, fiber_id)}
    end
  end

  defp schedule_retry(%State{} = state, fiber_id, attempt, metadata) when is_map(metadata) do
    previous = Map.get(state.retry_queue, fiber_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata, state.max_retry_backoff_ms)
    retry_token = make_ref()
    due_at_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond) + delay_ms

    # Cancel old timer if present
    if is_reference(previous[:timer_ref]) do
      Process.cancel_timer(previous.timer_ref)
    end

    # Target the poller via its registered name/pid, not `self()`. When
    # `schedule_retry` runs inside the poll-cycle Task spawned by
    # `handle_info(:run_poll_cycle, ...)`, `self()` is the Task pid; the
    # timer would fire into a dead process and the retry would never run.
    # `state.self_ref` is the poller's registered name (atom) or pid,
    # captured in init/1.
    timer_ref = Process.send_after(state.self_ref, {:retry, fiber_id, retry_token}, delay_ms)

    error = Map.get(metadata, :error)
    delay_type = Map.get(metadata, :delay_type, :failure)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.info(
      "Retry scheduled: fiber_id=#{fiber_id} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}"
    )

    retry_queue =
      Map.put(state.retry_queue, fiber_id, %{
        attempt: next_attempt,
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: due_at_ms,
        error: error,
        delay_type: delay_type
      })

    persist_retry(state, fiber_id, %{
      attempt: next_attempt,
      due_at_ms: due_at_ms,
      error: error,
      delay_type: delay_type
    })

    state = %{state | retry_queue: retry_queue, claimed: MapSet.put(state.claimed, fiber_id)}
    broadcast_snapshot(state)
    state
  end

  defp pop_retry(%State{} = state, fiber_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_queue, fiber_id) do
      %{retry_token: ^retry_token} = retry ->
        state =
          state
          |> delete_persisted_retry(fiber_id)
          |> Map.put(:retry_queue, Map.delete(state.retry_queue, fiber_id))

        {:ok, retry, state}

      _ ->
        :missing
    end
  end

  defp retry_delay(attempt, %{delay_type: :continuation}, _max_backoff) when attempt == 1 do
    @continuation_retry_delay_ms
  end

  defp retry_delay(attempt, _metadata, max_backoff) when is_integer(attempt) and attempt > 0 do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_backoff)
  end

  defp next_retry_attempt(state, fiber_id) do
    case Map.get(state.retry_queue, fiber_id) do
      %{attempt: attempt} when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> 1
    end
  end

  # ── Helpers ──

  defp already_running_session?(%State{} = state, session) do
    case state.runner.cmd("tmux", ["has-session", "-t", exact_tmux_target(session)],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

  defp exact_tmux_target(session), do: "=" <> session

  defp available_slots(%State{} = state) do
    max(state.max_concurrent_workers - map_size(state.running), 0)
  end

  defp release_claim(%State{} = state, fiber_id) do
    %{state | claimed: MapSet.delete(state.claimed, fiber_id)}
  end

  defp replace_matching_waiter(waiters, nil, nil), do: waiters

  defp replace_matching_waiter(waiters, channel_topic, notify_pid) do
    {replaced, remaining} =
      Enum.split_with(waiters, fn waiter ->
        (channel_topic && waiter.channel_topic == channel_topic) or
          (notify_pid && waiter.pid == notify_pid)
      end)

    Enum.each(replaced, &cancel_waiter_timeout/1)
    remaining
  end

  defp cancel_waiter_timeout(%{timeout_ref: timeout_ref}) when is_reference(timeout_ref) do
    Process.cancel_timer(timeout_ref)
  end

  defp cancel_waiter_timeout(_), do: :ok

  defp remove_running(%State{} = state, fiber_id) do
    delete_persisted_running(state, fiber_id)

    %{
      state
      | running: Map.delete(state.running, fiber_id),
        claimed: MapSet.delete(state.claimed, fiber_id)
    }
  end

  defp start_watcher(%State{} = state, fiber_id, metadata) do
    watcher_opts = [
      fiber_id: fiber_id,
      session: Map.fetch!(metadata, :session),
      poller: state.self_ref,
      runner: state.runner,
      heartbeat_interval_ms: state.heartbeat_interval_ms
    ]

    case DynamicSupervisor.start_child(Shuttle.WatcherSupervisor, {WorkerWatcher, watcher_opts}) do
      {:ok, watcher_pid} ->
        {:ok, Map.put(metadata, :pid, watcher_pid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_running(%State{} = state, fiber_id, metadata) do
    RuntimeStore.upsert_running(state.runtime_store_path, fiber_id, metadata)
  end

  defp delete_persisted_running(%State{} = state, fiber_id) do
    RuntimeStore.delete_running(state.runtime_store_path, fiber_id)
    state
  end

  defp persist_retry(%State{} = state, fiber_id, metadata) do
    RuntimeStore.upsert_retry(state.runtime_store_path, fiber_id, metadata)
  end

  defp delete_persisted_retry(%State{} = state, fiber_id) do
    RuntimeStore.delete_retry(state.runtime_store_path, fiber_id)
    state
  end

  # Append a felt history event noting the worker exit, including the
  # Claude/codex session UUID so it's archivally findable. Best-effort:
  # if felt isn't available or the index is busy, swallow the error and
  # log; the daemon's state machine must not be blocked on history writes.
  #
  # Surface for the user: `felt history <fiber-id>` lists every run with
  # its session UUID, agent, and reason. From there they can reattach
  # (`claude --resume <uuid>` directly) or shape a refinement via
  # `shuttle-ctl resume`.
  defp log_worker_exit(fiber_id, fiber, meta, reason, state) do
    session_uuid =
      case get_in(fiber, ["shuttle", "session", "id"]) do
        uuid when is_binary(uuid) and uuid != "" -> uuid
        _ -> nil
      end

    agent_id = Map.get(meta, :agent_id, "unknown")

    summary =
      if session_uuid do
        "worker exited (#{inspect(reason)}); agent=#{agent_id} session=#{session_uuid}"
      else
        "worker exited (#{inspect(reason)}); agent=#{agent_id} session=<unknown>"
      end

    case host_for_fiber(fiber_id, state) do
      {:ok, felt_store} ->
        args = ["-C", felt_store, "history", "append", fiber_id, "--summary", summary]

        try do
          case System.cmd("felt", args, stderr_to_stdout: true) do
            {_, 0} ->
              :ok

            {output, code} ->
              Logger.warning(
                "log_worker_exit: felt history append exited #{code} for #{fiber_id}: #{String.trim(output)}"
              )
          end
        rescue
          e ->
            Logger.warning(
              "log_worker_exit: felt history append raised for #{fiber_id}: #{inspect(e)}"
            )
        end

      {:error, _} ->
        Logger.debug(
          "log_worker_exit: no felt store found for #{fiber_id}; skipping history event"
        )
    end
  end

  defp reconcile_waiters(%State{waiters: waiters} = state) when map_size(waiters) == 0, do: state

  defp reconcile_waiters(%State{} = state) do
    remaining =
      Enum.filter(state.waiters, fn {fiber_id, waiters_list} ->
        case fetch_fiber_full(fiber_id, state) do
          {:ok, fiber} ->
            if Map.get(fiber, "tempered", false) do
              Enum.each(waiters_list, fn waiter ->
                cancel_waiter_timeout(waiter)

                if waiter.pid, do: send(waiter.pid, {:tempered, fiber_id})

                if waiter.channel_topic do
                  Phoenix.PubSub.broadcast(Shuttle.PubSub, waiter.channel_topic, %{
                    event: "tempered",
                    fiber_id: fiber_id
                  })
                end
              end)

              false
            else
              true
            end

          {:error, _} ->
            Enum.each(waiters_list, fn waiter ->
              cancel_waiter_timeout(waiter)

              if waiter.pid, do: send(waiter.pid, {:tempered_error, fiber_id, :not_found})

              if waiter.channel_topic do
                Phoenix.PubSub.broadcast(Shuttle.PubSub, waiter.channel_topic, %{
                  event: "error",
                  fiber_id: fiber_id,
                  reason: "not_found"
                })
              end
            end)

            false
        end
      end)

    %{state | waiters: Map.new(remaining)}
  end

  defp clean_expired_reservations(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    remaining = Enum.filter(state.reservations, fn {_key, res} -> res.expires_at_ms > now_ms end)
    %{state | reservations: Map.new(remaining)}
  end

  defp stop_watcher(meta) do
    if is_pid(meta.pid) and Process.alive?(meta.pid) do
      try do
        WorkerWatcher.stop(meta.pid)
      catch
        :exit, {:noproc, _} -> :ok
        :exit, :noproc -> :ok
      end
    end
  end

  # Fetch a fiber's full JSON representation via the felt CLI. Routes to the
  # fiber's owning host via host_for_fiber/2 (cache → file-stat probe).
  defp fetch_fiber_full(fiber_id, state) do
    host =
      case host_for_fiber(fiber_id, state) do
        {:ok, h} -> h
        {:error, _} -> hd(state.felt_stores)
      end

    case run_felt(host, state.runner, ["show", fiber_id, "--json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fiber} -> {:ok, fiber}
          {:error, _} -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp standing_role?(fiber, state) do
    # Tags no longer carry the standing signal; read the shuttle: block.
    case fetch_standing_role(Map.get(fiber, "id", ""), state) do
      {:ok, role} -> StandingRole.standing?(role)
      {:error, _} -> false
    end
  end

  defp standing_role_due?(fiber_id, state) do
    with true <- dependencies_satisfied?(fiber_id, state),
         {:ok, role} <- fetch_standing_role(fiber_id, state) do
      StandingRole.due?(role, DateTime.utc_now()) and
        not completed_standing_run?(
          state,
          fiber_id,
          StandingRole.next_run_id(role, DateTime.utc_now())
        )
    else
      _ -> false
    end
  end

  defp dispatch_prompt_context(fiber, state, opts) do
    fiber_id = Map.get(fiber, "id", "")

    case fetch_standing_role(fiber_id, state) do
      {:ok, role} ->
        if StandingRole.standing?(role) do
          now = DateTime.utc_now()

          if Keyword.get(opts, :ad_hoc, false) do
            {:standing_run, StandingRole.ad_hoc_run_id(now), :ad_hoc}
          else
            {:standing_run, StandingRole.next_run_id(role, now)}
          end
        else
          :constitution
        end

      _ ->
        :constitution
    end
  end

  defp running_prompt_metadata({:standing_run, run_id}), do: %{state: "running", run_id: run_id}

  defp running_prompt_metadata({:standing_run, run_id, :ad_hoc}),
    do: %{state: "running", run_id: run_id, run_kind: "ad_hoc"}

  defp running_prompt_metadata(_), do: %{}

  defp fetch_standing_role(fiber_id, state) do
    case fetch_shuttle_block(fiber_id, state) do
      {:ok, shuttle} -> StandingRole.from_map(fiber_id, shuttle)
      {:error, _} -> {:error, :no_shuttle_block}
    end
  end

  defp remember_completed_standing_run(state, _fiber_id, nil), do: state

  defp remember_completed_standing_run(state, fiber_id, run_id) do
    %{
      state
      | completed_standing_runs: MapSet.put(state.completed_standing_runs, {fiber_id, run_id})
    }
  end

  defp completed_standing_run?(state, fiber_id, run_id) do
    MapSet.member?(state.completed_standing_runs, {fiber_id, run_id})
  end

  defp standing_role_snapshots(roles, running, now) do
    Enum.map(roles, fn role ->
      StandingRole.to_snapshot(role, now, Map.has_key?(running, role.fiber_id))
    end)
  end

  # Run a felt CLI command against an explicit host directory.
  # Every felt-touching helper calls this directly with the resolved host.
  defp run_felt(host, runner, args) when is_binary(host) do
    opts = [cd: host, stderr_to_stdout: true]

    case runner.cmd("felt", args, opts) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  defp candidate_session_lookup(%State{} = state) do
    {:ok, candidates, _host_map} = discover_candidates(state)

    candidates
    |> Enum.reduce(%{}, fn fiber, acc ->
      case {Map.get(fiber, "id"), Map.get(fiber, "status")} do
        {fiber_id, status} when is_binary(fiber_id) and fiber_id != "" ->
          session = Dispatcher.session_name(fiber_id)
          bucket = if(status == "closed", do: :closed, else: :open)

          Map.update(acc, session, %{open: MapSet.new(), closed: MapSet.new()}, fn grouped ->
            Map.update!(grouped, bucket, &MapSet.put(&1, fiber_id))
          end)

        _ ->
          acc
      end
    end)
    |> Enum.into(%{}, fn {session, grouped} ->
      open_ids = Map.get(grouped, :open, MapSet.new()) |> MapSet.to_list()
      closed_ids = Map.get(grouped, :closed, MapSet.new()) |> MapSet.to_list()

      value =
        cond do
          length(open_ids) == 1 -> {:adopt, hd(open_ids)}
          length(open_ids) > 1 -> :ambiguous
          length(closed_ids) == 1 -> {:kill_closed, hd(closed_ids)}
          length(closed_ids) > 1 -> :ambiguous
          true -> nil
        end

      {session, value}
    end)
    |> Enum.reject(fn {_session, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp adopt_known_orphan_session(%State{} = state, lookup, session) do
    case Map.get(lookup, session) do
      {:adopt, fiber_id} ->
        if Map.has_key?(state.running, fiber_id) do
          state
        else
          adopt_session(state, fiber_id)
        end

      {:kill_closed, fiber_id} ->
        Logger.info("Killing stale session for closed fiber: #{fiber_id} session=#{session}")
        _ = state.runner.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
        state

      :ambiguous ->
        Logger.warning("Skipping orphan session with ambiguous leaf-only name: #{session}")
        state

      nil ->
        Logger.debug("Skipping orphan session with no matching fiber: #{session}")
        state
    end
  end

  defp list_shuttle_sessions(state) do
    case state.runner.cmd("tmux", ["ls", "-F", "\#{session_name}"], stderr_to_stdout: true) do
      {output, 0} ->
        sessions =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&Dispatcher.shuttle_session?/1)

        {:ok, sessions}

      {_, _} ->
        # No tmux server running
        {:ok, []}
    end
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle do
    # Small delay to let any pending messages settle
    :timer.send_after(20, self(), :run_poll_cycle)
    :ok
  end

  defp runtime_seconds(nil, _), do: 0

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp runtime_seconds(_, _), do: 0

  # Returns the configured felt stores list.
  #
  # Resolution order lives in `Shuttle.FeltStores`: `LOOM_HOMES` → persisted
  # `~/.shuttle/felt_stores.json` → `LOOM_HOME` → `~/loom`.
  #
  # This is the default-fallback only; explicit :felt_stores opts in start_link
  # take precedence via init/1 (and disable the per-poll refresh in that case).
  defp default_felt_stores do
    Shuttle.FeltStores.configured_hosts()
  end

  defp default_runtime_store_path do
    case System.get_env("SHUTTLE_RUNTIME_STORE") do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        if Application.get_env(:shuttle, :env) == :test do
          suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
          Path.join(System.tmp_dir!(), "shuttle-runtime-#{suffix}.db")
        else
          RuntimeStore.default_path()
        end
    end
  end

  # Re-reads the configured host list and updates state.felt_stores if the list
  # changed. Called from discover_candidates/1 each poll cycle so persisted
  # host registration or env changes are picked up without a daemon restart.
  # No-op when the caller passed an explicit :felt_stores opt
  # (state.auto_discover_felt_stores == false).
  defp refresh_felt_stores(%{auto_discover_felt_stores: false} = state), do: state

  defp refresh_felt_stores(%{felt_stores: current} = state) do
    fresh = default_felt_stores()

    if fresh == current do
      state
    else
      Logger.info("felt_stores updated from env/config: #{inspect(current)} → #{inspect(fresh)}")
      %{state | felt_stores: fresh}
    end
  end

  defp build_full_state(state) do
    snap = build_snapshot(state)

    running_detail =
      Enum.map(state.running, fn {fiber_id, meta} ->
        %{
          fiber_id: fiber_id,
          pid: inspect(meta.pid),
          session: meta.session,
          agent_id: meta.agent_id,
          started_at: DateTime.to_unix(meta.started_at, :millisecond),
          last_activity_at: DateTime.to_unix(meta.last_activity_at, :millisecond)
        }
      end)

    reservations =
      Enum.map(state.reservations, fn {{resource, host}, res} ->
        %{
          resource: resource,
          host: host,
          fiber_id: res.fiber_id,
          expires_in_ms: max(0, res.expires_at_ms - System.monotonic_time(:millisecond))
        }
      end)

    waiters =
      Enum.map(state.waiters, fn {fiber_id, waiters_list} ->
        %{fiber_id: fiber_id, waiter_count: length(waiters_list)}
      end)

    Map.merge(snap, %{
      running_detail: running_detail,
      reservations: reservations,
      waiters: waiters
    })
  end
end
