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

  alias Shuttle.{
    Actions,
    Dispatcher,
    LifecycleStore,
    RuntimeStore,
    StandingRole,
    WorkerWatcher
  }

  @pubsub_topic "shuttle:snapshot"

  @default_poll_interval_ms 30_000
  # Floor for the standing cron due-window so a fast test poll interval still
  # catches a tick that fired a beat before the poll. Cron resolution is one
  # minute, so the window must comfortably exceed it.
  @min_due_window_ms 90_000
  @default_max_concurrent_workers 10
  @default_heartbeat_interval_ms 5_000
  @default_stall_timeout_ms 300_000
  @dispatch_call_timeout_ms 30_000
  @orchestrator_state_call_timeout_ms 30_000
  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @default_max_retry_backoff_ms 300_000

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
      # Runtime/process registry. Keyed by intrinsic UID when known; metadata
      # carries :fiber_id as the felt address used for CLI shell-outs and
      # public API payloads.
      running: %{},
      claimed: MapSet.new(),
      retry_queue: %{},
      waiters: %{},
      reservations: %{},
      standing_roles: [],
      lifecycle: %{},
      orphans: [],
      # %{fiber_id => felt_store} — populated by discover_candidates/1 on each
      # poll cycle and by host_for_fiber/2 on demand. Entries are never evicted
      # automatically; call bust_fiber_host_cache/1 when a fiber moves hosts.
      fiber_host_cache: %{},
      # %{fiber_id => uid} — intrinsic frontmatter identity from felt's JSON
      # projection. The poller still addresses fibers by slug-shaped
      # fiber_id until the full dispatcher/session cutover carries path
      # resolution everywhere; uid is exposed on runtime surfaces as the join
      # key for document cards.
      fiber_uid_cache: %{},
      # %{uid_or_fiber_id => %{modified_at: String.t() | nil, entry: map()}} —
      # daemon-local document cache for the Portolan kanban feed. The poll task
      # diffs the cheap shuttle projection's modified_at against this cache and
      # runs full `felt show --json` only for cold or changed fibers.
      document_cache: %{},
      document_cache_stats: %{hits: 0, misses: 0, evictions: 0, entries: 0},
      document_cache_ready: false,
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

  @spec cached_fiber_documents(keyword() | GenServer.server()) :: {:ok, map()} | {:error, term()}
  def cached_fiber_documents(opts_or_server \\ [])

  def cached_fiber_documents(opts) when is_list(opts),
    do: cached_fiber_documents(__MODULE__, opts)

  def cached_fiber_documents(server), do: cached_fiber_documents(server, [])

  @spec cached_fiber_documents(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def cached_fiber_documents(server, opts) do
    GenServer.call(server, {:cached_fiber_documents, opts}, @orchestrator_state_call_timeout_ms)
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

  @doc """
  Run a standing-role lifecycle transition (`:accept` / `:resume`) through the
  Poller so the in-memory lifecycle cache is refreshed from the runtime store
  immediately after the write. Without this, `LifecycleStore.accept` writes the
  runtime DB but the next poll re-derives `state.lifecycle` from the stale
  in-memory copy and clobbers the write straight back to `awaiting` (see
  `merge_lifecycle_overlay` in the poll path). Running the transition inside the
  GenServer makes the DB write + cache refresh atomic against poll cycles.
  """
  @spec lifecycle_transition(:accept | :resume | :reset_review, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def lifecycle_transition(verb, fiber_id, opts \\ []),
    do: lifecycle_transition(__MODULE__, verb, fiber_id, opts)

  @spec lifecycle_transition(
          GenServer.server(),
          :accept | :resume | :reset_review,
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def lifecycle_transition(server, verb, fiber_id, opts) do
    GenServer.call(
      server,
      {:lifecycle_transition, verb, fiber_id, opts},
      @dispatch_call_timeout_ms
    )
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
    state =
      state
      |> rehydrate_lifecycle_store()
      |> rehydrate_runtime_store()
      |> adopt_orphans()
      |> rehydrate_retry_queue()

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

    # The Task does only the slow, READ-ONLY work (felt-store walk + remote
    # SSH discovery) and returns plain data — never a `%State{}`, never a
    # mutation, never an armed timer. Keeping the slow I/O off the GenServer
    # thread preserves daemon responsiveness; making it pure means there is
    # only one mutable state (the GenServer's), so there is nothing to merge
    # when the Task completes. See `poll_reads/1` and `apply_poll_cycle/2`.
    {:ok, _pid} =
      Task.start_link(fn ->
        send(parent, {:poll_world, poll_reads(state)})
      end)

    {:noreply, %{state | poll_check_in_progress: true}}
  end

  # The poll Task finished its reads. Apply the world it observed to the
  # GenServer's CURRENT state — anything that changed during the Task (a sync
  # :dispatch, a :worker_exited retry, a :retry firing) is already reflected
  # and is simply respected by the re-validating apply, never clobbered by a
  # stale snapshot.
  def handle_info({:poll_world, {:ok, world}}, state) do
    state =
      state
      |> apply_poll_cycle(world)
      |> Map.put(:poll_check_in_progress, false)
      |> schedule_tick(state.poll_interval_ms)

    broadcast_snapshot(state)
    {:noreply, state}
  end

  def handle_info({:poll_world, {:error, reason}}, state) do
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

  def handle_call({:cached_fiber_documents, opts}, _from, state) do
    if state.document_cache_ready do
      entries =
        state.document_cache
        |> Map.values()
        |> Enum.map(& &1.entry)
        |> Enum.sort_by(&get_in(&1, [:fiber, "id"]))

      stores = Keyword.get(opts, :felt_stores, state.felt_stores)
      {:reply, {:ok, Shuttle.FiberDocuments.envelope(stores, entries)}, state}
    else
      {:reply, {:error, :cold_document_cache}, state}
    end
  end

  def handle_call({:worker_status, fiber_id}, _from, state) do
    fiber_id = address_for_identifier(state, fiber_id)
    {:reply, running_worker(state, fiber_id), state}
  end

  def handle_call({:dispatch, fiber_id, opts}, _from, state) do
    fiber_id = address_for_identifier(state, fiber_id)
    state = reconcile_running_fiber(state, fiber_id)
    session = Dispatcher.session_name(fiber_id, uid_for_fiber(state, fiber_id))

    cond do
      running_key(state, fiber_id) != nil or MapSet.member?(state.claimed, fiber_id) ->
        {:reply, {:error, :already_running}, state}

      fiber_session_live?(state, fiber_id) ->
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
                {:reply, {:error, dispatch_ineligible_reason(fiber, state, opts)}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:actions, fiber_id, opts}, _from, state) do
    fiber_id = address_for_identifier(state, fiber_id)

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        fiber = overlay_runtime_lifecycle(fiber, fiber_id, state)
        running? = Keyword.get(opts, :running, live_running?(state, fiber_id))
        {:reply, {:ok, Actions.actions_for(fiber, running?)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_action, fiber_id, target, opts}, _from, state) do
    fiber_id = address_for_identifier(state, fiber_id)

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        fiber = overlay_runtime_lifecycle(fiber, fiber_id, state)
        running? = Keyword.get(opts, :running, live_running?(state, fiber_id))
        {:reply, Actions.resolve_transition(fiber, target, running?), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lifecycle_transition, verb, fiber_id, opts}, _from, state) do
    fiber_id = address_for_identifier(state, fiber_id)

    result =
      case verb do
        :accept -> LifecycleStore.accept(fiber_id, opts)
        :resume -> LifecycleStore.resume(fiber_id)
        :reset_review -> LifecycleStore.reset_review(fiber_id)
        other -> {:error, "unknown lifecycle transition #{inspect(other)}"}
      end

    case result do
      {:ok, output} ->
        {:reply, {:ok, output}, refresh_lifecycle_entry(state, fiber_id)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:wait, fiber_id, timeout_ms, opts}, _from, state) do
    fiber_id = address_for_identifier(state, fiber_id)
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
        # Cache the result so subsequent resolutions within the same daemon
        # lifetime skip the felt shell-out.
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
      Enum.map(state.running, fn {_runtime_key, meta} ->
        fiber_id = fiber_address(meta)

        %{
          fiber_id: fiber_id,
          uid: uid_for_fiber(state, fiber_id, meta),
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
      Enum.map(state.retry_queue, fn {_runtime_key, retry} ->
        fiber_id = fiber_address(retry)

        %{
          fiber_id: fiber_id,
          uid: uid_for_fiber(state, fiber_id, retry),
          attempt: retry.attempt,
          due_in_ms: max(0, retry.due_at_ms - now_ms),
          error: Map.get(retry, :error)
        }
      end)

    blocked =
      Enum.map(state.dispatch_failures, fn {fiber_id, entry} ->
        %{
          fiber_id: fiber_id,
          uid: uid_for_fiber(state, fiber_id),
          reason: format_block_reason(entry.reason),
          attempts: entry.attempts,
          attempted_at: DateTime.to_unix(entry.attempted_at, :millisecond),
          first_attempted_at: DateTime.to_unix(entry.first_attempted_at, :millisecond)
        }
      end)

    snap = %{
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
      standing_roles: standing_role_snapshots(state.standing_roles, state.running, now, state),
      claimed_count: MapSet.size(state.claimed),
      max_concurrent: state.max_concurrent_workers,
      document_cache: stringify_keys(state.document_cache_stats)
    }

    Map.put(snap, :runtime, runtime_by_fiber(state, snap, now))
  end

  defp runtime_by_fiber(%State{} = state, snap, now) do
    state.lifecycle
    |> Enum.reduce(%{}, fn {fiber_id, metadata}, acc ->
      Map.put(
        acc,
        runtime_entry_key(state, fiber_id, metadata),
        lifecycle_runtime(fiber_id, metadata, state)
      )
    end)
    |> merge_running_runtime(snap.eligible, state)
    |> merge_retry_runtime(snap.retrying, state)
    |> merge_standing_runtime(snap.standing_roles, now, state)
  end

  defp lifecycle_runtime(fiber_id, metadata, state) do
    review = stringify_keys(Map.get(metadata, :review, %{}))

    %{
      fiber_id: fiber_id,
      uid: uid_for_fiber(state, fiber_id, metadata),
      kind: Map.get(metadata, :kind, "oneshot"),
      phase: Map.get(metadata, :phase) || Map.get(review, "state") || "scheduled",
      run_id: Map.get(metadata, :run_id),
      run_kind: Map.get(metadata, :run_kind),
      session: stringify_keys(Map.get(metadata, :session, %{})),
      review: review,
      next_due_at: unix_ms(Map.get(metadata, :next_due_at)),
      last_run_at: unix_ms(Map.get(metadata, :last_run_at))
    }
    |> compact_runtime()
  end

  defp merge_running_runtime(runtime, running, state) do
    Enum.reduce(running, runtime, fn worker, acc ->
      fiber_id = worker.fiber_id
      runtime_key = runtime_entry_key(state, fiber_id, worker)

      Map.update(acc, runtime_key, running_runtime(worker, state), fn existing ->
        existing
        |> Map.merge(running_runtime(worker, state))
        |> Map.put(:phase, "running")
      end)
    end)
  end

  defp running_runtime(worker, state) do
    %{
      fiber_id: worker.fiber_id,
      uid: uid_for_fiber(state, worker.fiber_id, worker),
      phase: "running",
      running: true,
      tmux_session: worker.tmux_session,
      agent: worker.agent,
      run_id: worker.run_id,
      started_at: worker.started_at,
      last_activity_at: worker.last_activity_at,
      runtime_seconds: worker.runtime_seconds
    }
    |> compact_runtime()
  end

  defp merge_retry_runtime(runtime, retrying, state) do
    Enum.reduce(retrying, runtime, fn retry, acc ->
      fiber_id = retry.fiber_id
      runtime_key = runtime_entry_key(state, fiber_id, retry)

      Map.update(acc, runtime_key, retry_runtime(retry, state), fn existing ->
        existing
        |> Map.merge(retry_runtime(retry, state))
        |> Map.put(:phase, "retrying")
      end)
    end)
  end

  defp retry_runtime(retry, state) do
    %{
      fiber_id: retry.fiber_id,
      uid: uid_for_fiber(state, retry.fiber_id, retry),
      phase: "retrying",
      retry: %{
        attempt: retry.attempt,
        due_in_ms: retry.due_in_ms,
        error: retry.error
      }
    }
    |> compact_runtime()
  end

  defp merge_standing_runtime(runtime, standing_roles, now, state) do
    Enum.reduce(standing_roles, runtime, fn role, acc ->
      fiber_id = role.fiber_id
      runtime_key = runtime_entry_key(state, fiber_id)

      Map.update(acc, runtime_key, standing_runtime(role, now, state), fn existing ->
        existing
        |> Map.merge(standing_runtime(role, now, state))
        |> preserve_active_phase()
      end)
    end)
  end

  defp standing_runtime(role, now, state) do
    %{
      fiber_id: role.fiber_id,
      uid: uid_for_fiber(state, role.fiber_id),
      kind: "standing",
      phase: standing_phase(role),
      state: role.state,
      run_id: role.run_id,
      next_due_at: role.next_due_at,
      last_run_at: role.last_run_at,
      review: role.review,
      schedule: role.schedule,
      validation_errors: role.validation_errors,
      due_in_ms: due_in_ms(role.next_due_at, now)
    }
    |> compact_runtime()
  end

  defp standing_phase(%{state: "running"}), do: "running"
  defp standing_phase(%{state: "dormant"}), do: "dormant"
  defp standing_phase(%{state: "due"}), do: "due"
  defp standing_phase(%{review: %{"state" => state}}) when is_binary(state), do: state
  defp standing_phase(_), do: "scheduled"

  defp preserve_active_phase(%{phase: phase} = runtime) when phase in ["running", "retrying"] do
    runtime
  end

  defp preserve_active_phase(runtime), do: runtime

  defp compact_runtime(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, %{}} -> true
      {_key, []} -> true
      _ -> false
    end)
  end

  defp due_in_ms(nil, _now), do: nil

  defp due_in_ms(next_due_at, now) when is_integer(next_due_at) do
    max(0, next_due_at - DateTime.to_unix(now, :millisecond))
  end

  defp due_in_ms(_, _now), do: nil

  defp unix_ms(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :millisecond)
  defp unix_ms(value) when is_integer(value), do: value
  defp unix_ms(_), do: nil

  defp uid_for_fiber(%State{} = state, fiber_id, metadata \\ %{}) do
    case metadata_uid(metadata) || Map.get(state.fiber_uid_cache, fiber_id) do
      uid when is_binary(uid) and uid != "" -> uid
      _ -> nil
    end
  end

  defp runtime_entry_key(%State{} = state, fiber_id, metadata \\ %{}) do
    uid_for_fiber(state, fiber_id, metadata) || fiber_id
  end

  defp runtime_key_for_fiber(fiber) when is_map(fiber) do
    fiber_id = fiber_address(fiber)
    metadata_uid(fiber) || fiber_id
  end

  defp runtime_key_for_address(%State{} = state, fiber_id, metadata) do
    uid_for_fiber(state, fiber_id, metadata) || fiber_id
  end

  defp address_for_identifier(%State{} = state, identifier) when is_binary(identifier) do
    cond do
      Map.has_key?(state.fiber_uid_cache, identifier) ->
        identifier

      true ->
        address_from_runtime_maps(state, identifier) ||
          address_from_uid_cache(state, identifier) ||
          address_from_felt_stores(identifier) ||
          identifier
    end
  end

  defp address_for_identifier(_state, identifier), do: identifier

  defp address_from_uid_cache(%State{} = state, uid) do
    Enum.find_value(state.fiber_uid_cache, fn {fiber_id, cached_uid} ->
      if cached_uid == uid, do: fiber_id
    end)
  end

  defp address_from_runtime_maps(%State{} = state, identifier) do
    [state.running, state.retry_queue, state.lifecycle]
    |> Enum.find_value(fn records ->
      Enum.find_value(records, fn {_key, metadata} ->
        address = fiber_address(metadata)
        uid = metadata_uid(metadata)

        if identifier in [address, uid], do: address
      end)
    end)
  end

  defp address_from_felt_stores(identifier) do
    case Shuttle.FeltStores.resolve_fiber(identifier) do
      {:ok, %{fiber_id: fiber_id}} -> fiber_id
      {:error, :not_found} -> nil
    end
  end

  defp fiber_address(metadata) when is_map(metadata) do
    case Map.get(metadata, :fiber_id) || Map.get(metadata, "fiber_id") ||
           Map.get(metadata, "id") || Map.get(metadata, :id) do
      fiber_id when is_binary(fiber_id) and fiber_id != "" -> fiber_id
      _ -> ""
    end
  end

  defp running_key(%State{} = state, fiber_id) when is_binary(fiber_id) do
    cond do
      Map.has_key?(state.running, fiber_id) ->
        fiber_id

      true ->
        Enum.find_value(state.running, fn {key, metadata} ->
          address = fiber_address(metadata)
          uid = metadata_uid(metadata)

          if fiber_id in [address, uid], do: key
        end)
    end
  end

  defp running_key(_, _), do: nil

  defp running_worker(%State{} = state, fiber_id) do
    case running_key(state, fiber_id) do
      nil -> nil
      key -> Map.get(state.running, key)
    end
  end

  defp retry_key(%State{} = state, fiber_id) when is_binary(fiber_id) do
    cond do
      Map.has_key?(state.retry_queue, fiber_id) ->
        fiber_id

      true ->
        Enum.find_value(state.retry_queue, fn {key, metadata} ->
          address = fiber_address(metadata)
          uid = metadata_uid(metadata)

          if fiber_id in [address, uid], do: key
        end)
    end
  end

  defp retry_key(_, _), do: nil

  defp retry_record(%State{} = state, fiber_id) do
    case retry_key(state, fiber_id) do
      nil -> nil
      key -> Map.get(state.retry_queue, key)
    end
  end

  defp lifecycle_key(%State{} = state, fiber_id) when is_binary(fiber_id) do
    cond do
      Map.has_key?(state.lifecycle, fiber_id) ->
        fiber_id

      true ->
        Enum.find_value(state.lifecycle, fn {key, metadata} ->
          address = fiber_address(metadata)
          uid = metadata_uid(metadata)

          if fiber_id in [address, uid], do: key
        end)
    end
  end

  defp lifecycle_key(_, _), do: nil

  defp lifecycle_record(%State{} = state, fiber_id) do
    case lifecycle_key(state, fiber_id) do
      nil -> nil
      key -> Map.get(state.lifecycle, key)
    end
  end

  defp metadata_uid(metadata) when is_map(metadata) do
    case {Map.get(metadata, :uid), Map.get(metadata, "uid")} do
      {uid, _} when is_binary(uid) and uid != "" -> uid
      {_, uid} when is_binary(uid) and uid != "" -> uid
      _ -> nil
    end
  end

  defp metadata_uid(_), do: nil

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

  # READ-ONLY poll work, run inside the poll Task. Walks felt stores (local +
  # remote over SSH) to discover candidate fibers; returns plain data. It never
  # mutates state, runs an effect, or arms a timer — so there is nothing to
  # merge back when it completes (`apply_poll_cycle/2` does the mutating work on
  # the live GenServer). The rescue/catch turns a felt/SSH explosion into a
  # logged `{:error, _}` rather than a crash that would take the linked poller
  # down with the Task.
  defp poll_reads(%State{} = state) do
    state = refresh_felt_stores(state)
    {:ok, candidates, host_map, uid_map} = discover_candidates(state)
    {document_cache, document_cache_stats} = refresh_document_cache(state, candidates, host_map)

    {:ok,
     %{
       felt_stores: state.felt_stores,
       candidates: candidates,
       host_map: host_map,
       uid_map: uid_map,
       document_cache: document_cache,
       document_cache_stats: document_cache_stats
     }}
  rescue
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  # Apply an observed `world` (from `poll_reads/1`) to the GenServer's CURRENT
  # state. This is the only place the poll cycle reconciles, dispatches, or
  # schedules retries, and it runs on the live GenServer process — so anything
  # that changed during the Task's read is reflected in `state` and respected
  # here, never overwritten from a stale snapshot. Reconcile is reordered after
  # discovery (it was before, in the old single-pass `maybe_dispatch`); the two
  # are independent given refreshed felt stores, and reconcile now sees current
  # `running` rather than the Task's snapshot.
  defp apply_poll_cycle(%State{} = state, %{
         felt_stores: felt_stores,
         candidates: candidates,
         host_map: new_host_map,
         uid_map: new_uid_map,
         document_cache: document_cache,
         document_cache_stats: document_cache_stats
       }) do
    state = reconcile(%{state | felt_stores: felt_stores})

    # Merge newly resolved host entries into the cache. Existing entries
    # are not evicted — earlier-configured hosts win for ID collisions,
    # and cache entries are stable for the daemon's lifetime.
    state =
      state
      |> reconcile_persisted_running(candidates, new_uid_map)
      |> reconcile_persisted_lifecycle(candidates, new_uid_map)

    {standing_roles, lifecycle} = standing_roles_from_candidates(candidates, state)

    state = %{
      state
      | fiber_host_cache: Map.merge(new_host_map, state.fiber_host_cache),
        fiber_uid_cache: Map.merge(new_uid_map, state.fiber_uid_cache),
        document_cache: document_cache,
        document_cache_stats: document_cache_stats,
        document_cache_ready: true,
        standing_roles: standing_roles,
        lifecycle: Map.merge(state.lifecycle, lifecycle),
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

  # Detect fibers that were dispatched at least once (runtime session.id set)
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
  # Standing roles are excluded *here* because their dead-worker outcome is not
  # resurrection (a continuation retry) but awaiting review: the document flips
  # to `status: closed`. That mark is written upstream, in
  # `record_orphaned_running_worker`, the moment the dead running entry is
  # detected — so by the time this pass runs the role is already closed and the
  # `status == "closed"` clause below leaves it alone.
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

    lifecycle = runtime_lifecycle(state, fiber_id)
    session_id = stored_session_id(state, fiber_id, fiber)
    lifecycle_dispatched? = Map.get(lifecycle, :phase) == "dispatched"

    cond do
      # Only the owning daemon may resurrect. A fiber owned by another host
      # (or unowned — absent host:) is not this daemon's orphan; leave it for
      # the owning daemon or the kanban. This is the load-bearing gate: a
      # remote restart must never re-grab a Mac-owned fiber whose loom-synced
      # runtime store carries a stale session UUID (the 2026-05-30 incident).
      not host_owned?(shuttle, state.own_host_id) ->
        state

      # A declared project_dir absent on this host disqualifies resurrection
      # too — same rule as the poll path.
      not project_dir_available?(shuttle) ->
        state

      # Standing roles don't resurrect — a dead standing worker becomes
      # awaiting review (status:closed), written in
      # `record_orphaned_running_worker` before this pass. Never retry one.
      kind == "standing" ->
        state

      # Never dispatched — nothing to resurrect. A runtime row with
      # phase=dispatched is also a dispatch marker: session capture is
      # best-effort, and if it failed we still need to move the dead launch into
      # retry instead of leaving the card in "dispatched" forever.
      session_id == nil and not lifecycle_dispatched? ->
        state

      # Closed — work is done.
      status == "closed" ->
        state

      # Already tracking (a WorkerWatcher is alive for this fiber).
      running_key(state, fiber_id) != nil ->
        state

      # Retry already queued.
      MapSet.member?(state.claimed, fiber_id) ->
        state

      # tmux session for this fiber is live (either name form) — `adopt_orphans`
      # / `reconcile_orphaned_sessions` will pick it up; not our problem.
      Enum.any?(
        Dispatcher.session_names(fiber_id, Map.get(fiber, "uid")),
        &MapSet.member?(live_sessions, &1)
      ) ->
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

  # Discovers candidate fibers by asking felt for a narrow shuttle projection
  # per configured store and keeping the ones physically rooted in that store.
  # No tag predicate — the shuttle: block is the source of truth, matching the
  # same contract every other surface reads.
  #
  # Returns {:ok, fibers, host_map, uid_map} where:
  #   fibers   — [%{"id" => id, "uid" => uid, "status" => status, "path" => …}] across all hosts
  #   host_map — %{fiber_id => felt_store} for host resolution
  #   uid_map  — %{fiber_id => uid} for the intrinsic identity read surface
  #
  # ## Symlink discipline
  #
  # The same physical fiber file is often reachable from multiple felt hosts via
  # symlinks. Two cases that occur in practice:
  #
  # 1. A project host (`~/work/project-a`) whose `.felt/` is a symlink into
  #    `~/loom/.felt/work/project-a/`. The same `task-board.md` is reachable as
  #    `task-board` (project view) and `work/project-a/task-board` (loom view).
  #
  # 2. A project-canonical felt store (lightcone) whose own `.felt/` is a real
  #    directory, with loom symlinking *into* it at
  #    `~/loom/.felt/ai-futures/lightcone -> ~/lightcone/.felt`. The same fiber
  #    is reachable as `lightcone-ui/...` (lightcone view) and
  #    `ai-futures/lightcone/lightcone-ui/...` (loom view).
  #
  # If both views were enumerated, dispatch would race: each "different" id
  # passes `tmux has-session` independently → multiple workers on one file.
  #
  # **Rule: a fiber is enumerated only by the host where it is physically
  # rooted.** `list_shuttle_fibers/2` enforces this by reading felt's carried
  # `path` (absolute, symlink-resolved) and keeping a fiber iff that path lives
  # under `realpath(host)/.felt/` — so case 2's loom view drops the fiber (its
  # realpath roots in lightcone) and the lightcone store claims it. A store
  # whose own `.felt/` is a symlink (case 1) owns nothing; the target store
  # enumerates it. Ownership is read from felt's path, never reverse-derived.
  defp discover_candidates(state) do
    {all_fibers, host_map, uid_map} =
      Enum.reduce(state.felt_stores, {[], %{}, %{}}, fn host, {acc_fibers, acc_map, acc_uids} ->
        case list_shuttle_fibers(host, state) do
          {:ok, fibers} ->
            new_map =
              Enum.reduce(fibers, %{}, fn fiber, hm ->
                id = Map.get(fiber, "id", "")
                Map.put(hm, id, host)
              end)

            new_uids =
              Enum.reduce(fibers, %{}, fn fiber, uids ->
                case {Map.get(fiber, "id"), Map.get(fiber, "uid")} do
                  {id, uid} when is_binary(id) and id != "" and is_binary(uid) and uid != "" ->
                    Map.put(uids, id, uid)

                  _ ->
                    uids
                end
              end)

            merged_map = Map.merge(new_map, acc_map)
            merged_uids = Map.merge(new_uids, acc_uids)
            {acc_fibers ++ fibers, merged_map, merged_uids}

          {:error, _} ->
            {acc_fibers, acc_map, acc_uids}
        end
      end)

    {:ok, all_fibers, host_map, uid_map}
  end

  defp refresh_document_cache(%State{} = state, candidates, host_map) do
    previous = state.document_cache

    {cache, stats} =
      Enum.reduce(candidates, {%{}, %{hits: 0, misses: 0}}, fn candidate, {cache_acc, stats} ->
        key = document_cache_key(candidate)
        modified_at = Map.get(candidate, "modified_at")
        cached = Map.get(previous, key)

        if reusable_document_cache_entry?(cached, modified_at) do
          {Map.put(cache_acc, key, cached), Map.update!(stats, :hits, &(&1 + 1))}
        else
          case fetch_document_cache_entry(state, candidate, host_map) do
            {:ok, entry} ->
              cached = %{modified_at: modified_at, entry: entry}
              {Map.put(cache_acc, key, cached), Map.update!(stats, :misses, &(&1 + 1))}

            {:error, reason} ->
              Logger.warning(
                "document cache refresh skipped #{Map.get(candidate, "id", "(unknown)")}: #{inspect(reason)}"
              )

              if cached do
                {Map.put(cache_acc, key, cached), Map.update!(stats, :hits, &(&1 + 1))}
              else
                {cache_acc, Map.update!(stats, :misses, &(&1 + 1))}
              end
          end
        end
      end)

    stats =
      stats
      |> Map.put(:evictions, max(map_size(previous) - map_size(cache), 0))
      |> Map.put(:entries, map_size(cache))

    {cache, stats}
  end

  defp document_cache_key(candidate) do
    case Map.get(candidate, "uid") do
      uid when is_binary(uid) and uid != "" -> uid
      _ -> Map.get(candidate, "id", "")
    end
  end

  defp reusable_document_cache_entry?(%{modified_at: modified_at, entry: entry}, modified_at)
       when is_map(entry),
       do: true

  defp reusable_document_cache_entry?(_, _), do: false

  defp fetch_document_cache_entry(state, candidate, host_map) do
    with id when is_binary(id) and id != "" <- Map.get(candidate, "id"),
         store when is_binary(store) <- Map.get(host_map, id),
         {:ok, output} <- run_felt(store, state.runner, ["show", id, "--json"]),
         {:ok, %{} = fiber} <- Jason.decode(output),
         [entry | _] <- Shuttle.FiberDocuments.entries_for_fiber(store, Map.delete(fiber, "body")) do
      {:ok, entry}
    else
      nil -> {:error, :missing_store}
      "" -> {:error, :missing_id}
      {:error, error} -> {:error, error}
      [] -> {:error, :invalid_entry}
      _ -> {:error, :invalid_json}
    end
  end

  # Read one host's shuttle fibers via felt's JSON, keeping only those
  # PHYSICALLY ROOTED in this host. Ownership is read from felt's carried
  # `path` (absolute, symlink-resolved) — a fiber belongs to `host` iff its
  # path lives under `realpath(host)/.felt/`. felt enumerates symlink-traversed
  # fibers too (loom listing a project whose `.felt` is symlinked in), so the
  # path-prefix check is what keeps each fiber owned by exactly the store that
  # physically roots it — the discipline the old filesystem walk + canonical-id
  # match enforced, now read from felt rather than reverse-derived. A store
  # whose own `.felt/` is a symlink owns nothing here: the target store
  # enumerates it canonically.
  defp list_shuttle_fibers(host, state) do
    felt_dir = Path.join(host, ".felt")

    case File.lstat(felt_dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, []}

      {:ok, %File.Stat{type: :directory}} ->
        # An empty store has nothing to enumerate; skip the felt shell-out so a
        # store with no fibers costs nothing (and so a daemon polling an empty
        # configured store doesn't shell felt every tick).
        if empty_dir?(felt_dir) do
          {:ok, []}
        else
          run_shuttle_listing(host, state)
        end

      _ ->
        {:ok, []}
    end
  end

  defp empty_dir?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries == []
      _ -> true
    end
  end

  defp run_shuttle_listing(host, state) do
    case run_felt_ls_for_shuttle(host, state) do
      {:ok, output} ->
        with {:ok, fibers} when is_list(fibers) <- Jason.decode(output) do
          owned_prefix = store_felt_realpath(host) <> "/"

          kept =
            Enum.filter(fibers, fn fiber ->
              is_map(Map.get(fiber, "shuttle")) and owned_by_store?(fiber, owned_prefix)
            end)

          {:ok, kept}
        else
          _ -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A fiber is owned by this store iff felt's carried physical `path` lives
  # under `realpath(host)/.felt/`. No `path` (older felt) means we cannot
  # confirm ownership, so the fiber is conservatively dropped — the owning
  # store, where felt does carry a matching path, enumerates it.
  defp owned_by_store?(%{"path" => path}, owned_prefix) when is_binary(path) and path != "" do
    String.starts_with?(path, owned_prefix)
  end

  defp owned_by_store?(_, _), do: false

  defp run_felt_ls_for_shuttle(host, state) do
    # Cheap projection: felt filters by raw top-level frontmatter first, then
    # emits only fields the poller needs for eligibility, ownership, and identity.
    # Keep the broad fallback so a not-yet-upgraded remote felt fails soft
    # instead of hiding every card on that city.
    case run_felt(host, state.runner, [
           "ls",
           "--json",
           "--has-field",
           "shuttle",
           "--json-field",
           "id,uid,status,shuttle,path,modified_at"
         ]) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} ->
        Logger.warning(
          "shuttle felt ls failed for #{host}; falling back to broad listing: #{inspect(reason)}"
        )

        run_felt(host, state.runner, ["ls", "--json"])
    end
  end

  # Realpath of `<host>/.felt`, resolving symlinks along the path so the
  # ownership prefix matches felt's symlink-resolved `path`. Resolves segment by
  # segment via `:file.read_link`; falls back to `Path.expand` for any segment
  # that isn't a symlink. Self-contained so the poller carries no cross-module
  # realpath dependency.
  defp store_felt_realpath(host) do
    felt_dir = host |> Path.join(".felt") |> Path.expand()

    case resolve_realpath(felt_dir) do
      {:ok, resolved} -> resolved
      {:error, _} -> felt_dir
    end
  end

  @max_symlink_hops 40

  defp resolve_realpath(path) do
    case Path.split(Path.expand(path)) do
      ["/" | rest] -> resolve_realpath_segments("/", rest, 0)
      [first | rest] -> resolve_realpath_segments(first, rest, 0)
      [] -> {:error, :empty_path}
    end
  end

  defp resolve_realpath_segments(current, [], _hops), do: {:ok, current}

  defp resolve_realpath_segments(_current, _segments, hops) when hops > @max_symlink_hops,
    do: {:error, :symlink_loop}

  defp resolve_realpath_segments(current, [segment | rest], hops) do
    candidate = Path.join(current, segment)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target_path = List.to_string(target)

        expanded_target =
          case Path.type(target_path) do
            :absolute -> Path.expand(target_path)
            _ -> Path.expand(target_path, Path.dirname(candidate))
          end

        case Path.split(expanded_target) do
          ["/" | target_rest] -> resolve_realpath_segments("/", target_rest ++ rest, hops + 1)
          [first | target_rest] -> resolve_realpath_segments(first, target_rest ++ rest, hops + 1)
          [] -> {:error, :empty_target}
        end

      {:error, _} ->
        resolve_realpath_segments(candidate, rest, hops)
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

        # Closed is the awaiting-review / anti-oscillation gate. A closed fiber
        # is never dispatch-eligible — a oneshot terminus, or (new model) a
        # standing role that ran this cycle and is `status: closed` + untempered
        # pending a human verdict. Re-arming is an explicit accept that writes
        # `status: active`; until then closed stays dormant. Made explicit (not
        # only implied by `status in [open, active]` below) so a tempered fiber
        # can never oscillate back to dispatching on a later poll — the
        # citation-audit-skill tempered-never-reverts invariant.
        status == "closed" ->
          false

        # Must be committed to active work
        status not in ["open", "active"] ->
          false

        # Must not already be running
        running_key(state, fiber_id) != nil ->
          false

        # Must not be claimed (retry queued)
        MapSet.member?(state.claimed, fiber_id) ->
          false

        # Standing roles have additional preconditions; oneshots go to dep check.
        # Support both new-format (kind:) and old-format (mode:) shuttle blocks.
        Map.get(shuttle, "kind", Map.get(shuttle, "mode", "oneshot")) == "standing" ->
          standing_role_due?(fiber, state)

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

  # Names WHY a dispatch was refused so the kanban can say something true
  # instead of the catch-all "disabled, not yet due, or closed". The most
  # common confusing case is a remote-homed fiber dispatched against the wrong
  # daemon: a force-dispatch of a `host: cineca` fiber that reaches any daemon
  # whose `own_host_id != cineca` fails `host_owned?` and used to report a flat
  # `not_eligible`. The reason atoms (`:homed_elsewhere`, `:project_dir_missing`,
  # `:disabled`, `:closed`, `:human_worker`, `:no_shuttle_block`,
  # `:not_due_or_blocked`) are surfaced to the UI as accurate copy.
  #
  # Only called on the ineligible branch, so the eligible (dispatch-now) path is
  # untouched. For a force/ad_hoc dispatch the irreducible gate is `force_*`'s;
  # for a plain dispatch the fuller `eligible?` rules apply, so the reason is
  # computed against the same `force` intent the caller passed.
  defp dispatch_ineligible_reason(fiber, state, opts) do
    shuttle = Map.get(fiber, "shuttle")
    status = Map.get(fiber, "status", "")
    forced? = Keyword.get(opts, :force, false) or Keyword.get(opts, :ad_hoc, false)

    cond do
      not is_map(shuttle) ->
        {:not_eligible, :no_shuttle_block}

      human_worker?(fiber) ->
        {:not_eligible, :human_worker}

      not host_owned?(shuttle, state.own_host_id) ->
        {:not_eligible, {:homed_elsewhere, Map.get(shuttle, "host"), state.own_host_id}}

      not project_dir_available?(shuttle) ->
        {:not_eligible, {:project_dir_missing, Map.get(shuttle, "project_dir")}}

      # The remaining cases only gate a NON-forced dispatch (force overrides
      # status/enabled). Report them so a plain dispatch failure is legible.
      not forced? and Map.get(shuttle, "enabled", false) != true ->
        {:not_eligible, :disabled}

      not forced? and status == "closed" ->
        {:not_eligible, :closed}

      true ->
        {:not_eligible, :not_due_or_blocked}
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

  defp standing_roles_from_candidates(candidates, state) do
    candidates
    |> Enum.reduce({[], %{}}, fn fiber, {roles, lifecycle} ->
      case standing_role_from_fiber(fiber, state) do
        {:ok, role} ->
          if StandingRole.standing?(role) do
            metadata =
              role
              |> lifecycle_metadata_from_role()
              |> Map.put(:uid, Map.get(fiber, "uid"))

            persist_lifecycle(state, role.fiber_id, metadata)
            runtime_key = runtime_key_for_address(state, role.fiber_id, metadata)
            {[role | roles], Map.put(lifecycle, runtime_key, metadata)}
          else
            {roles, lifecycle}
          end

        {:error, _} ->
          {roles, lifecycle}
      end
    end)
    |> then(fn {roles, lifecycle} -> {Enum.reverse(roles), lifecycle} end)
  end

  defp standing_role_from_fiber(fiber, state) do
    fiber_id = Map.get(fiber, "id", "")

    case Map.get(fiber, "shuttle") do
      shuttle when is_map(shuttle) ->
        shuttle
        |> merge_lifecycle_overlay(lifecycle_record(state, fiber_id))
        |> then(&StandingRole.from_map(fiber_id, &1))

      _ ->
        {:error, :no_shuttle_block}
    end
  end

  defp merge_lifecycle_overlay(shuttle, nil), do: shuttle

  defp merge_lifecycle_overlay(shuttle, lifecycle) when is_map(shuttle) and is_map(lifecycle) do
    shuttle
    |> put_if_missing("review", stringify_keys(Map.get(lifecycle, :review, %{})))
    |> put_if_missing("next_due_at", Map.get(lifecycle, :next_due_at))
    |> put_if_missing("last_run_at", Map.get(lifecycle, :last_run_at))
    |> put_if_missing("session", stringify_keys(Map.get(lifecycle, :session, %{})))
  end

  # Resolves which configured felt store owns `fiber_id` — the store root used
  # to shell subsequent felt commands, NOT the shuttle.host dispatch-affinity
  # field.
  #
  # Resolution order:
  # 1. State cache (fast; populated by discover_candidates/1 each poll cycle)
  # 2. Ask felt: `FeltStores.resolve_fiber/2` (against THIS daemon's
  #    `state.felt_stores`) shells `felt show -j` (or a uid scan) and reports the
  #    owning store directly, reading felt's carried path rather than
  #    reconstructing or globbing candidate files.
  #
  # Returns {:ok, host} for the store that owns the fiber, or {:error,
  # :not_found} when no configured store claims it.
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
        case Shuttle.FeltStores.resolve_fiber(fiber_id, state.felt_stores) do
          {:ok, %{host: host}} -> {:ok, host}
          {:error, :not_found} -> {:error, :not_found}
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
           force: Keyword.get(opts, :force, false),
           runtime_session_id: stored_session_id(state, fiber_id, fiber)
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
        runtime_key = runtime_key_for_fiber(fiber)

        running_meta =
          %{
            fiber_id: fiber_id,
            session: session,
            agent_id: agent.id,
            uid: Map.get(fiber, "uid"),
            started_at: now,
            last_activity_at: now
          }
          |> Map.merge(running_prompt_metadata(prompt_context))

        case start_watcher(state, fiber_id, running_meta) do
          {:ok, running_meta} ->
            running = Map.put(state.running, runtime_key, running_meta)
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
                uid: Map.get(fiber, "uid"),
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
    Enum.reduce(state.running, state, fn {runtime_key, meta}, state_acc ->
      fiber_id = fiber_address(meta)

      case fetch_fiber_full(fiber_id, state_acc) do
        {:ok, fiber} ->
          if Map.get(fiber, "status") == "closed" do
            Logger.info("Fiber closed externally: #{fiber_id}; stopping watcher")
            stop_watcher(meta)
            remove_running(state_acc, runtime_key)
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
    Enum.reduce(state.running, state, fn {runtime_key, %{session: session} = meta}, state_acc ->
      fiber_id = fiber_address(meta)

      if already_running_session?(state_acc, session) do
        state_acc
      else
        Logger.info("Detected missing worker session: #{fiber_id} session=#{session}")
        stop_watcher(meta)

        state_acc
        |> record_orphaned_running_worker(fiber_id, meta)
        |> remove_running(runtime_key)
      end
    end)
  end

  defp record_orphaned_running_worker(%State{} = state, fiber_id, meta) do
    # Daemon-down analog of handle_worker_exit's standing branch. Both callers
    # — `rehydrate_running_record` (init, the daemon was down when the worker
    # died) and `reconcile_missing_running_sessions` (runtime, the watcher
    # missed the exit) — land here for a running entry whose tmux session is
    # gone. For an ordinary oneshot that's just an orphan to record; for a
    # standing role it is the exit that `handle_worker_exit` never got to run,
    # so the armed document would re-fire on the next poll. Mark it awaiting
    # (status:closed, untempered) here, keyed on the running-worker entry — a
    # role that never dispatched this cycle (e.g. a stale awaiting overlay with
    # no running row, like the live daily-practice wedge) never reaches this
    # path and cannot be regressed.
    mark_dead_standing_role_awaiting(state, fiber_id)

    orphan = %{
      fiber_id: fiber_id,
      tmux_session: Map.get(meta, :session),
      agent: Map.get(meta, :agent_id),
      reason: "missing_tmux_session",
      detected_at: DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    }

    %{state | orphans: [orphan | state.orphans]}
  end

  # Write `status: closed` (untempered) to a standing role's document when its
  # worker died unobserved and the document is still armed. Only an owned,
  # armed (status:active, no verdict) standing role is touched; oneshots, roles
  # this daemon doesn't own, and already-closed/tempered roles are left alone.
  # The mark is idempotent: once status flips to closed the running entry is
  # gone (the caller removes it) and the `status == "active"` guard short-
  # circuits any later pass.
  defp mark_dead_standing_role_awaiting(%State{} = state, fiber_id) do
    with {:ok, fiber} <- fetch_fiber_full(fiber_id, state),
         shuttle when is_map(shuttle) <- Map.get(fiber, "shuttle"),
         true <- host_owned?(shuttle, state.own_host_id),
         true <- standing_block?(shuttle),
         "active" <- Map.get(fiber, "status", ""),
         true <- is_nil(Map.get(fiber, "tempered")) do
      Logger.info(
        "Standing role #{fiber_id} worker died unobserved (daemon-down or unwatched " <>
          "exit); marking awaiting (status:closed) so the armed document does not re-fire"
      )

      mark_standing_awaiting(fiber_id)
    else
      _ -> :ok
    end
  end

  # Direct read of the standing signal from a shuttle: block, with no lifecycle
  # overlay merge (unlike `standing_role?/2`). Supports both the new `kind:` and
  # legacy `mode:` shapes.
  defp standing_block?(shuttle) when is_map(shuttle) do
    Map.get(shuttle, "kind", Map.get(shuttle, "mode")) == "standing"
  end

  defp standing_block?(_), do: false

  defp rehydrate_runtime_store(%State{} = state) do
    state.runtime_store_path
    |> RuntimeStore.list_running()
    |> Enum.reduce(state, fn %{fiber_id: fiber_id, runtime_key: runtime_key, metadata: metadata},
                             state_acc ->
      rehydrate_running_record(state_acc, fiber_id, runtime_key, metadata)
    end)
  end

  defp rehydrate_retry_queue(%State{} = state) do
    state.runtime_store_path
    |> RuntimeStore.list_retries()
    |> Enum.reduce(state, fn %{fiber_id: fiber_id, metadata: metadata}, state_acc ->
      rehydrate_retry_record(state_acc, fiber_id, metadata)
    end)
  end

  defp rehydrate_lifecycle_store(%State{} = state) do
    lifecycle =
      state.runtime_store_path
      |> RuntimeStore.list_lifecycle()
      |> Map.new(fn %{fiber_id: fiber_id, runtime_key: runtime_key, metadata: metadata} ->
        {runtime_key, metadata |> Map.put_new(:fiber_id, fiber_id)}
      end)

    %{state | lifecycle: lifecycle}
  end

  defp reconcile_persisted_lifecycle(%State{} = state, candidates, uid_map) do
    {candidate_ids, uid_to_address} = runtime_reconcile_indexes(candidates, uid_map)

    lifecycle =
      Enum.reduce(state.lifecycle, %{}, fn {runtime_key, metadata}, acc ->
        address =
          case fiber_address(metadata) do
            "" -> Map.get(uid_to_address, runtime_key, runtime_key)
            fiber_id -> fiber_id
          end

        uid = metadata_uid(metadata) || Map.get(uid_map, address)

        known? =
          MapSet.member?(candidate_ids, address) or Map.has_key?(uid_to_address, runtime_key)

        cond do
          known? and is_binary(uid) and uid != "" and
              (runtime_key != uid or metadata_uid(metadata) != uid or
                 fiber_address(metadata) != address) ->
            migrated = metadata |> Map.put(:fiber_id, address) |> Map.put(:uid, uid)

            if runtime_key != uid do
              RuntimeStore.delete_lifecycle_key(state.runtime_store_path, runtime_key)
            end

            RuntimeStore.upsert_lifecycle(state.runtime_store_path, address, migrated)
            Map.put(acc, uid, migrated)

          true ->
            Map.put(acc, runtime_key, metadata)
        end
      end)

    %{state | lifecycle: lifecycle}
  end

  defp reconcile_persisted_running(%State{} = state, candidates, uid_map) do
    {candidate_ids, uid_to_address} = runtime_reconcile_indexes(candidates, uid_map)

    running =
      Enum.reduce(state.running, %{}, fn {runtime_key, metadata}, acc ->
        address =
          case fiber_address(metadata) do
            "" -> Map.get(uid_to_address, runtime_key, runtime_key)
            fiber_id -> fiber_id
          end

        uid = metadata_uid(metadata) || Map.get(uid_map, address)

        known? =
          MapSet.member?(candidate_ids, address) or Map.has_key?(uid_to_address, runtime_key)

        cond do
          known? and is_binary(uid) and uid != "" and
              (runtime_key != uid or metadata_uid(metadata) != uid or
                 fiber_address(metadata) != address) ->
            migrated = metadata |> Map.put(:fiber_id, address) |> Map.put(:uid, uid)

            if runtime_key != uid do
              RuntimeStore.delete_running_key(state.runtime_store_path, runtime_key)
            end

            RuntimeStore.upsert_running(state.runtime_store_path, address, migrated)
            Map.put(acc, uid, migrated)

          true ->
            Map.put(acc, runtime_key, metadata)
        end
      end)

    %{state | running: running}
  end

  defp runtime_reconcile_indexes(candidates, uid_map) do
    candidate_ids =
      candidates
      |> Enum.map(&Map.get(&1, "id", ""))
      |> MapSet.new()

    uid_to_address = Map.new(uid_map, fn {address, uid} -> {uid, address} end)

    {candidate_ids, uid_to_address}
  end

  defp runtime_lifecycle(%State{} = state, fiber_id) do
    RuntimeStore.fetch_lifecycle(state.runtime_store_path, fiber_id) ||
      lifecycle_record(state, fiber_id) ||
      %{}
  end

  # Overlay daemon-owned runtime lifecycle (review state, next_due_at, …) onto a
  # fiber's `shuttle:` block before action classification. Standing-role review
  # state lives in the runtime store, not the frontmatter (LifecycleStore evicts
  # it), so `fetch_fiber_full` — which reads only `felt show --json` — returns a
  # fiber whose `review.state` always looks like the default `scheduled`. Action
  # availability would then disagree with `/state` (which is runtime-derived),
  # rejecting valid transitions like accept-run with `action_not_available`.
  # Reads the runtime store DB-first so resolution is correct even if the
  # in-memory cache lags a just-landed transition.
  defp overlay_runtime_lifecycle(fiber, fiber_id, %State{} = state) do
    case Map.get(fiber, "shuttle") do
      shuttle when is_map(shuttle) ->
        Map.put(
          fiber,
          "shuttle",
          merge_lifecycle_overlay(shuttle, runtime_lifecycle(state, fiber_id))
        )

      _ ->
        fiber
    end
  end

  # Refresh a single fiber's in-memory lifecycle entry from the runtime store
  # after an external transition wrote it. Keeps `state.lifecycle` in lock-step
  # with the DB so the next poll's `merge_lifecycle_overlay` reads the new state
  # instead of clobbering it back.
  defp refresh_lifecycle_entry(%State{} = state, fiber_id) do
    case RuntimeStore.fetch_lifecycle(state.runtime_store_path, fiber_id) do
      metadata when is_map(metadata) ->
        runtime_key = runtime_key_for_address(state, fiber_id, metadata)

        %{
          state
          | lifecycle:
              state.lifecycle
              |> Map.delete(fiber_id)
              |> Map.put(runtime_key, metadata)
        }

      _ ->
        case lifecycle_key(state, fiber_id) do
          nil -> state
          runtime_key -> %{state | lifecycle: Map.delete(state.lifecycle, runtime_key)}
        end
    end
  end

  defp lifecycle_session_id(metadata) when is_map(metadata) do
    case Map.get(metadata, :session) do
      %{"id" => id} when is_binary(id) and id != "" -> id
      %{id: id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp lifecycle_session_id(_), do: nil

  defp legacy_frontmatter_session_id(fiber) do
    case get_in(fiber, ["shuttle", "session", "id"]) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  defp stored_session_id(%State{} = state, fiber_id, fiber) do
    runtime_session_id =
      state
      |> runtime_lifecycle(fiber_id)
      |> lifecycle_session_id()

    runtime_session_id || legacy_frontmatter_session_id(fiber)
  end

  defp rehydrate_retry_record(%State{} = state, fiber_id, metadata) do
    cond do
      running_key(state, fiber_id) != nil ->
        delete_persisted_retry(state, fiber_id)

      retry_key(state, fiber_id) != nil ->
        state

      true ->
        attempt = Map.get(metadata, :attempt, 1)

        due_at_ms =
          Map.get(metadata, :due_at_ms, DateTime.to_unix(DateTime.utc_now(), :millisecond))

        delay_ms = max(0, due_at_ms - DateTime.to_unix(DateTime.utc_now(), :millisecond))
        retry_token = make_ref()
        timer_ref = Process.send_after(state.self_ref, {:retry, fiber_id, retry_token}, delay_ms)

        retry = %{
          fiber_id: fiber_id,
          uid: Map.get(metadata, :uid),
          attempt: attempt,
          timer_ref: timer_ref,
          retry_token: retry_token,
          due_at_ms: due_at_ms,
          error: Map.get(metadata, :error),
          delay_type: Map.get(metadata, :delay_type, :failure)
        }

        runtime_key = runtime_key_for_address(state, fiber_id, retry)

        Logger.info(
          "Rehydrated retry: fiber_id=#{fiber_id} in #{delay_ms}ms (attempt #{attempt})"
        )

        %{
          state
          | retry_queue: Map.put(state.retry_queue, runtime_key, retry),
            claimed: MapSet.put(state.claimed, fiber_id)
        }
    end
  end

  defp rehydrate_running_record(%State{} = state, fiber_id, runtime_key, metadata) do
    session =
      Map.get(metadata, :session) ||
        Dispatcher.session_name(fiber_id, uid_for_fiber(state, fiber_id, metadata))
    existing_key = running_key(state, fiber_id)

    cond do
      existing_key != nil and metadata_uid(metadata) != nil and existing_key != runtime_key ->
        RuntimeStore.delete_running_key(state.runtime_store_path, existing_key)
        running_meta = Map.merge(Map.fetch!(state.running, existing_key), metadata)

        %{
          state
          | running:
              state.running
              |> Map.delete(existing_key)
              |> Map.put(runtime_key, running_meta)
        }

      existing_key != nil ->
        RuntimeStore.delete_running_key(state.runtime_store_path, runtime_key)
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
                  runtime_key = runtime_key_for_address(state, fiber_id, running_meta)

                  %{
                    state
                    | running: Map.put(state.running, runtime_key, running_meta),
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

  # `session` is the *live* tmux session name to adopt. Callers that discovered
  # a live orphan pass its exact name (which may be the legacy leaf-only form on
  # a worker launched before the uid-keyed cutover); the default picks whichever
  # of the fiber's name forms is actually live (preferring the uid-keyed name),
  # for callers that only have the fiber identity.
  defp adopt_session(state, fiber_id, session \\ nil) do
    session =
      session || live_session_for_fiber(state, fiber_id) ||
        Dispatcher.session_name(fiber_id, uid_for_fiber(state, fiber_id))

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        if Map.get(fiber, "status") != "closed" do
          agent_name = fetch_shuttle_agent_name(fiber_id, state)
          {:ok, agent} = Shuttle.Agents.resolve_by_name(agent_name)

          now = DateTime.utc_now()

          running_meta = %{
            fiber_id: fiber_id,
            session: session,
            agent_id: agent.id,
            uid: Map.get(fiber, "uid"),
            started_at: now,
            last_activity_at: now
          }

          case start_watcher(state, fiber_id, running_meta) do
            {:ok, running_meta} ->
              runtime_key = runtime_key_for_fiber(fiber)
              running = Map.put(state.running, runtime_key, running_meta)
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

    case running_key(state, fiber_id) do
      nil ->
        state

      runtime_key ->
        case Map.pop(state.running, runtime_key) do
          {nil, _} ->
            state

          {meta, running} ->
            state = %{state | running: running}
            fiber_id = fiber_address(meta)

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
                    # New model: a standing worker's exit makes the role
                    # awaiting review by writing `status: closed` (untempered)
                    # to the felt document — the don't-re-fire gate and the
                    # human's accept anchor, both now doc-representable. Write
                    # BEFORE release_claim so the document reflects awaiting
                    # before the claim frees (a re-poll racing the release then
                    # reads `status: closed` and skips re-dispatch).
                    mark_standing_awaiting(fiber_id)

                    release_claim(state, fiber_id)

                  true ->
                    # Still active — schedule continuation retry
                    attempt = next_retry_attempt(state, fiber_id)

                    schedule_retry(state, fiber_id, attempt, %{
                      uid: metadata_uid(meta),
                      delay_type: :continuation
                    })
                end

              {:error, _} ->
                # Can't read fiber — schedule failure retry
                attempt = next_retry_attempt(state, fiber_id)

                schedule_retry(state, fiber_id, attempt, %{
                  uid: metadata_uid(meta),
                  error: "fiber read failed after exit"
                })
            end
        end
    end
  end

  # Write the standing-role awaiting marker (`status: closed`, untempered) to the
  # felt document on worker exit. Best-effort: a failed felt write must not crash
  # the exit-handling state machine (the worker is already gone; the dead-orphan
  # reconciler is the backstop), so we log and continue. The felt-history exit
  # event is written separately by `log_worker_exit`.
  defp mark_standing_awaiting(fiber_id) do
    case LifecycleStore.mark_awaiting(fiber_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to mark standing role #{fiber_id} awaiting on exit: #{reason}")
        :error
    end
  end

  # ── Retry ──

  # Whether a fiber is GENUINELY running right now: in the registry AND its tmux
  # session is actually alive. The read legs (:actions / :resolve_action) use
  # this instead of a raw `Map.has_key?(state.running, …)`, so a resolved action
  # agrees with what the dispatch leg's `reconcile_running_fiber` would conclude.
  # Unlike reconcile, this is a PURE read — no watcher teardown, no state
  # mutation — so resolve/actions stay side-effect-free; the actual eviction
  # happens on the next poll tick or the dispatch leg. Without it, in the window
  # after a worker's session dies the registry still reports it running, so a
  # drag→inFlight resolves to `pause` for a worker that no longer exists and the
  # matching invoke (which reconciles) 409s. (C1-adjacent.)
  defp live_running?(%State{} = state, fiber_id) do
    case running_worker(state, fiber_id) do
      nil -> false
      %{session: session} -> already_running_session?(state, session)
    end
  end

  defp reconcile_running_fiber(%State{} = state, fiber_id) do
    case {running_key(state, fiber_id), running_worker(state, fiber_id)} do
      {nil, _} ->
        state

      {_, nil} ->
        state

      {runtime_key, %{session: session} = meta} ->
        fiber_id = fiber_address(meta)

        if already_running_session?(state, session) do
          state
        else
          Logger.info("Clearing stale running worker: #{fiber_id} session=#{session}")
          stop_watcher(meta)
          remove_running(state, runtime_key)
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

            state
            |> clear_stale_orphan_lifecycle(fiber_id, retry)
            |> release_claim(fiber_id)
          end

        {:noreply, state}

      {:error, _} ->
        Logger.debug("Retry fiber not found: #{fiber_id}")
        {:noreply, release_claim(state, fiber_id)}
    end
  end

  defp clear_stale_orphan_lifecycle(%State{} = state, fiber_id, retry) do
    lifecycle = runtime_lifecycle(state, fiber_id)
    kind = Map.get(lifecycle, :kind, "oneshot")

    if Map.get(retry, :delay_type) == :continuation and kind == "oneshot" and
         Map.get(lifecycle, :phase) == "dispatched" do
      Logger.info("Clearing stale orphan dispatch lifecycle: fiber_id=#{fiber_id}")
      RuntimeStore.delete_lifecycle(state.runtime_store_path, fiber_id)
      refresh_lifecycle_entry(state, fiber_id)
    else
      state
    end
  end

  defp schedule_retry(%State{} = state, fiber_id, attempt, metadata) when is_map(metadata) do
    previous_key = retry_key(state, fiber_id)
    previous = if previous_key, do: Map.get(state.retry_queue, previous_key), else: nil
    previous = previous || %{attempt: 0}
    next_attempt = if is_integer(attempt), do: attempt, else: previous.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata, state.max_retry_backoff_ms)
    retry_token = make_ref()
    due_at_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond) + delay_ms

    # Cancel old timer if present
    if is_reference(previous[:timer_ref]) do
      Process.cancel_timer(previous.timer_ref)
    end

    # Target the poller via its registered name/pid (`state.self_ref`, captured
    # in init/1), not `self()`. Retry scheduling now always runs on the GenServer
    # — worker-exit, retry-firing, and the poll cycle's `apply_poll_cycle/2` all
    # execute in-process — so `self()` would in fact be the poller here. We keep
    # `self_ref` regardless: it is correct unconditionally, survives a restart,
    # and removes any dependence on which process armed the timer.
    timer_ref = Process.send_after(state.self_ref, {:retry, fiber_id, retry_token}, delay_ms)

    error = Map.get(metadata, :error)
    delay_type = Map.get(metadata, :delay_type, :failure)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.info(
      "Retry scheduled: fiber_id=#{fiber_id} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}"
    )

    retry = %{
      fiber_id: fiber_id,
      uid: Map.get(metadata, :uid) || Map.get(state.fiber_uid_cache, fiber_id),
      attempt: next_attempt,
      timer_ref: timer_ref,
      retry_token: retry_token,
      due_at_ms: due_at_ms,
      error: error,
      delay_type: delay_type
    }

    runtime_key = runtime_key_for_address(state, fiber_id, retry)

    retry_queue =
      state.retry_queue
      |> maybe_delete_key(previous_key)
      |> Map.put(runtime_key, retry)

    persist_retry(state, fiber_id, %{
      uid: Map.get(retry, :uid),
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
    key = retry_key(state, fiber_id)

    case key && Map.get(state.retry_queue, key) do
      %{retry_token: ^retry_token} = retry ->
        fiber_id = fiber_address(retry)

        state =
          state
          |> delete_persisted_retry(fiber_id)
          |> Map.put(:retry_queue, Map.delete(state.retry_queue, key))

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
    case retry_record(state, fiber_id) do
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

  # Dual-recognition liveness: a fiber is running if a live tmux session exists
  # under either its uid-keyed name or the legacy leaf-only name. Used wherever
  # the caller has the fiber identity but not a stored session name.
  defp fiber_session_live?(%State{} = state, fiber_id) do
    live_session_for_fiber(state, fiber_id) != nil
  end

  # The fiber's *live* tmux session name (either form), preferring the uid-keyed
  # canonical name when both happen to exist. Returns nil when neither is live.
  defp live_session_for_fiber(%State{} = state, fiber_id) do
    fiber_id
    |> Dispatcher.session_names(uid_for_fiber(state, fiber_id))
    |> Enum.find(&already_running_session?(state, &1))
  end

  defp exact_tmux_target(session), do: "=" <> session

  defp available_slots(%State{} = state) do
    max(state.max_concurrent_workers - map_size(state.running), 0)
  end

  defp release_claim(%State{} = state, fiber_id) do
    %{state | claimed: MapSet.delete(state.claimed, fiber_id)}
  end

  defp maybe_delete_key(map, nil), do: map
  defp maybe_delete_key(map, key), do: Map.delete(map, key)

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
    metadata = Map.get(state.running, fiber_id, %{})
    address = fiber_address(metadata)
    delete_persisted_running(state, fiber_id)

    %{
      state
      | running: Map.delete(state.running, fiber_id),
        claimed: state.claimed |> MapSet.delete(fiber_id) |> MapSet.delete(address)
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
    session_uuid = stored_session_id(state, fiber_id, fiber)

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
  # fiber's owning host via host_for_fiber/2 (cache → felt resolution).
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

      # run_felt already wraps a non-zero exit in a descriptive
      # `felt -C <host> show <id> failed: <stderr>` string. A common case here
      # is a felt-store path that doesn't exist on THIS host — e.g. a foreign
      # absolute path (`/Users/.../loom`) that another machine's portolan
      # registered. Surfacing the path + stderr instead of a bare reason is what
      # turns the old undiagnosable blank 500 into an actionable error. See
      # `gotcha-remote-daemon-foreign-felt-store-path`.
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

  # Standing dispatch is gated by the FELT DOCUMENT, not the runtime review
  # overlay (the slice-1 cutover) and not a stored `next_due_at` (the slice-2
  # cutover). A role dispatches iff its document says `status: active` with no
  # verdict (`tempered` unset) AND the cron schedule fired a tick inside the
  # poll window ending at now. `status: closed` (untempered) is the
  # awaiting-review / don't-re-fire signal — eligible?'s `status == "closed"`
  # clause already excludes it before this is reached, and the
  # `active → closed → active` document transition is the per-cycle "already ran
  # this cycle" gate (replacing the old `completed_standing_runs` MapSet). The
  # runtime review overlay still drives the kanban *display* (StandingRole.state)
  # until it is removed in slice 4; it no longer drives dispatch.
  defp standing_role_due?(fiber, state) do
    fiber_id = Map.get(fiber, "id", "")

    with true <- Map.get(fiber, "status", "") == "active",
         true <- is_nil(Map.get(fiber, "tempered")),
         true <- dependencies_satisfied?(fiber_id, state),
         {:ok, role} <- fetch_standing_role(fiber_id, state) do
      StandingRole.due_by_cron?(role, DateTime.utc_now(), due_window_ms(state))
    else
      _ -> false
    end
  end

  # The cron due-window: a standing tick is due if it fired inside
  # `(now - window, now]`. Anchored to the poll interval (doubled for jitter
  # slack, with a floor) so consecutive polls' windows overlap and no tick falls
  # between them, while a tick that fired before the window — daemon down across
  # it — is skipped, not replayed (the morning-post-drift rule).
  defp due_window_ms(%State{poll_interval_ms: interval}) when is_integer(interval) and interval > 0,
    do: max(interval * 2, @min_due_window_ms)

  defp due_window_ms(_), do: @min_due_window_ms

  defp dispatch_prompt_context(fiber, state, opts) do
    fiber_id = Map.get(fiber, "id", "")

    case fetch_standing_role(fiber_id, state) do
      {:ok, role} ->
        if StandingRole.standing?(role) do
          now = DateTime.utc_now()

          if Keyword.get(opts, :ad_hoc, false) do
            {:standing_run, StandingRole.ad_hoc_run_id(now), :ad_hoc}
          else
            # A resumed run keeps the awaiting run's id so the review-comment
            # window covers the just-filed resume directive; only a fresh
            # scheduled run mints a new id. See StandingRole.dispatch_run_id.
            {:standing_run, StandingRole.dispatch_run_id(role, now)}
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
      {:ok, shuttle} ->
        shuttle
        |> merge_lifecycle_overlay(lifecycle_record(state, fiber_id))
        |> then(&StandingRole.from_map(fiber_id, &1))

      {:error, _} ->
        {:error, :no_shuttle_block}
    end
  end

  defp lifecycle_metadata_from_role(%StandingRole{} = role) do
    %{
      fiber_id: role.fiber_id,
      kind: role.mode || "standing",
      phase: role.review["state"] || "scheduled",
      run_id: role.run_id,
      next_due_at: role.next_due_at,
      last_run_at: role.last_run_at,
      review: role.review
    }
  end

  defp persist_lifecycle(%State{} = state, fiber_id, metadata) do
    RuntimeStore.upsert_lifecycle(state.runtime_store_path, fiber_id, metadata)
  end

  defp put_if_missing(map, _key, nil), do: map
  defp put_if_missing(map, _key, value) when value == %{}, do: map

  defp put_if_missing(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      "" -> Map.put(map, key, value)
      %{} = nested when map_size(nested) == 0 -> Map.put(map, key, value)
      _ -> map
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_), do: %{}

  defp standing_role_snapshots(roles, running, now, state) do
    state = %{state | running: running}

    Enum.map(roles, fn role ->
      running? = running_key(state, role.fiber_id) != nil

      role
      |> StandingRole.to_snapshot(now, running?)
      # Display next_due is computed cron.next(now): `active` means
      # armed-for-the-next-occurrence, so the upcoming run is the schedule's next
      # tick, not a stored timestamp (the slice-2 cutover). Falls back to the
      # snapshot's stored value when the schedule won't parse.
      |> put_computed_next_due(role, now)
      |> Map.put(:uid, uid_for_fiber(state, role.fiber_id))
    end)
  end

  defp put_computed_next_due(snapshot, %StandingRole{} = role, now) do
    case StandingRole.next_due_from_cron(role, now) do
      %DateTime{} = next -> Map.put(snapshot, :next_due_at, DateTime.to_unix(next, :millisecond))
      _ -> snapshot
    end
  end

  # Run a felt CLI command against an explicit host directory.
  # Every felt-touching helper calls this directly with the resolved host.
  #
  # On a non-zero exit, the error is a self-describing string carrying the
  # command, the host directory it ran in, the exit status, and trimmed
  # stderr. felt's own stderr for a nonexistent store can be empty (it just
  # finds no index), which previously bubbled up as a BLANK `{:error, ""}` →
  # an undiagnosable 500 at the ActionsController boundary. Including the host
  # path names the actual fault — typically a felt-store path that doesn't
  # exist on this machine (a foreign absolute path registered by another
  # host's portolan).
  defp run_felt(host, runner, args) when is_binary(host) do
    opts = [cd: host, stderr_to_stdout: true]

    case runner.cmd("felt", args, opts) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        trimmed = String.trim(to_string(output))
        detail = if trimmed == "", do: "(no output)", else: trimmed
        {:error, "felt #{Enum.join(args, " ")} (cd #{host}) exited #{status}: #{detail}"}
    end
  end

  # Maps every live tmux session name a candidate could carry — both the
  # uid-keyed canonical name and the legacy leaf-only name — back to its fiber,
  # so orphan adoption recognizes a worker launched under either scheme. The
  # uid-keyed entries are inherently collision-free; the legacy leaf-only
  # entries keep the existing ambiguity guard (two fibers sharing a leaf resolve
  # to `:ambiguous` and are skipped rather than mis-adopted).
  defp candidate_session_lookup(%State{} = state) do
    {:ok, candidates, _host_map, _uid_map} = discover_candidates(state)

    candidates
    |> Enum.reduce(%{}, fn fiber, acc ->
      case {Map.get(fiber, "id"), Map.get(fiber, "status")} do
        {fiber_id, status} when is_binary(fiber_id) and fiber_id != "" ->
          bucket = if(status == "closed", do: :closed, else: :open)

          fiber_id
          |> Dispatcher.session_names(Map.get(fiber, "uid"))
          |> Enum.reduce(acc, fn session, acc2 ->
            Map.update(acc2, session, %{open: MapSet.new(), closed: MapSet.new()}, fn grouped ->
              Map.update!(grouped, bucket, &MapSet.put(&1, fiber_id))
            end)
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
        if running_key(state, fiber_id) != nil do
          state
        else
          adopt_session(state, fiber_id, session)
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
      Enum.map(state.running, fn {runtime_key, meta} ->
        fiber_id = fiber_address(meta)

        %{
          runtime_key: runtime_key,
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
