defmodule Shuttle.Poller do
  @moduledoc """
  Polls the felt fiber tree and dispatches workers for eligible constitutions.

  A single GenServer owns the dispatch tick, eligibility predicate, retry
  scheduling, and reconciliation. It starts `Shuttle.WorkerWatcher` processes
  under a `DynamicSupervisor` to track each worker's tmux session from outside.

  Lifted from Symphony's orchestrator.ex with the integration layer replaced:
  - Linear API → felt CLI
  - Issue model → fiber model
  - Codex app-server → tmux + loom shell wrappers

  ## Multi-host support

  The Poller manages one or more felt hosts on the same machine. Configure via:

      config :shuttle, felt_hosts: ["~/loom", "~/wedding", "~/Documents/projects/lightcone"]
      # or env var (comma-separated, takes precedence over config):
      LOOM_HOMES=~/loom,~/wedding,~/Documents/projects/lightcone

  Single-host setups (the common case) are unchanged: `felt_hosts` defaults to
  `[LOOM_HOME || ~/loom]`.

  Each fiber resolves to exactly one host: the first configured host whose
  `.felt/` directory contains the fiber file. The resolution is cached in
  `State.fiber_host_cache` for the daemon's lifetime. Call
  `bust_fiber_host_cache/1` or `POST /api/v1/cache/bust` to evict an entry
  when a fiber moves between hosts.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Shuttle.{Dispatcher, StandingRole, WorkerWatcher}

  @pubsub_topic "shuttle:snapshot"

  @default_poll_interval_ms 30_000
  @default_max_concurrent_workers 10
  @default_heartbeat_interval_ms 5_000
  @default_stall_timeout_ms 300_000
  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @default_max_retry_backoff_ms 300_000

  defmodule State do
    @moduledoc false
    defstruct [
      :poll_interval_ms,
      :max_concurrent_workers,
      :heartbeat_interval_ms,
      :stall_timeout_ms,
      :max_retry_backoff_ms,
      :next_poll_due_at_ms,
      :tick_timer_ref,
      :tick_token,
      # List of felt host directories, in resolution-priority order.
      :felt_hosts,
      # When true, felt_hosts is re-read from the env + portolan cities each
      # poll cycle so newly-pinned cities pop up live without a daemon restart.
      # Set true when :felt_hosts opt isn't passed to start_link; false when
      # caller passed an explicit list (tests, manual overrides — respect them).
      :auto_discover_felt_hosts,
      :runner,
      poll_check_in_progress: false,
      running: %{},
      claimed: MapSet.new(),
      retry_queue: %{},
      waiters: %{},
      reservations: %{},
      completed_standing_runs: MapSet.new(),
      # %{fiber_id => felt_host} — populated by discover_candidates/1 on each
      # poll cycle and by host_for_fiber/2 on demand. Entries are never evicted
      # automatically; call bust_fiber_host_cache/1 when a fiber moves hosts.
      fiber_host_cache: %{}
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
    GenServer.call(server, {:dispatch, fiber_id, opts})
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
    GenServer.call(server, :orchestrator_state)
  end

  @doc """
  Returns `{:ok, felt_host}` for the first configured host that contains
  `fiber_id`, or `{:error, :not_found}` if the fiber isn't in any host.

  The result is cached in the Poller's state for the daemon's lifetime.
  Used by `GET /api/v1/fiber/:id/host` so external callers (portolan,
  shuttle-ctl) can route their felt operations to the right index without
  re-implementing host resolution.
  """
  @spec resolve_fiber_host(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve_fiber_host(fiber_id), do: resolve_fiber_host(__MODULE__, fiber_id)

  @spec resolve_fiber_host(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found}
  def resolve_fiber_host(server, fiber_id) do
    GenServer.call(server, {:resolve_fiber_host, fiber_id})
  end

  @doc """
  Evicts the cached felt-host resolution for `fiber_id`. The daemon
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

    {felt_hosts, auto_discover} =
      case Keyword.fetch(opts, :felt_hosts) do
        {:ok, hosts} -> {hosts, false}
        :error -> {default_felt_hosts(), true}
      end

    runner = Keyword.get(opts, :runner, Shuttle.Runner.Default)

    state = %State{
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
      felt_hosts: felt_hosts,
      auto_discover_felt_hosts: auto_discover,
      runner: runner
    }

    # Adopt existing tmux sessions on startup
    state = adopt_orphans(state)

    # Schedule first tick immediately
    state = schedule_tick(state, 0)
    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    :ok = schedule_poll_cycle()
    {:noreply, state}
  end

  def handle_info({:tick, _}, state), do: {:noreply, state}

  def handle_info(:run_poll_cycle, state) do
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
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

  def handle_call({:dispatch, fiber_id, _opts}, _from, state) do
    session = Dispatcher.session_name(fiber_id)

    cond do
      Map.has_key?(state.running, fiber_id) or MapSet.member?(state.claimed, fiber_id) ->
        {:reply, {:error, :already_running}, state}

      already_running_session?(state, session) ->
        {:reply, {:error, :already_running}, state}

      true ->
        case fetch_fiber_full(fiber_id, state) do
          {:ok, fiber} ->
            if eligible?(fiber, state) do
              new_state = do_dispatch_fiber(state, fiber)

              if Map.has_key?(new_state.running, fiber_id) do
                {:reply, {:ok, session}, new_state}
              else
                {:reply, {:error, :dispatch_failed}, new_state}
              end
            else
              {:reply, {:error, :not_eligible}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
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

  # ── Snapshot ──

  @spec build_snapshot(State.t()) :: map()
  defp build_snapshot(state) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    eligible =
      Enum.map(state.running, fn {fiber_id, meta} ->
        %{
          fiber_id: fiber_id,
          felt_host: Map.get(state.fiber_host_cache, fiber_id),
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

    %{
      poll_at: now_ms,
      host: hostname(),
      felt_hosts: state.felt_hosts,
      eligible: eligible,
      blocked: [],
      orphans: [],
      retrying: retrying,
      standing_roles: standing_role_snapshots(state, now),
      claimed_count: MapSet.size(state.claimed),
      max_concurrent: state.max_concurrent_workers
    }
  end

  defp broadcast_snapshot(state) do
    snap = build_snapshot(state)
    Phoenix.PubSub.broadcast(Shuttle.PubSub, @pubsub_topic, {:snapshot, snap})
    snap
  end

  # ── Dispatch ──

  defp maybe_dispatch(%State{} = state) do
    state = state |> refresh_felt_hosts() |> reconcile()

    with {:ok, candidates, new_host_map} <- discover_candidates(state),
         true <- available_slots(state) > 0 do
      # Merge newly resolved host entries into the cache. Existing entries
      # are not evicted — earlier-configured hosts win for ID collisions,
      # and cache entries are stable for the daemon's lifetime.
      state = %{state | fiber_host_cache: Map.merge(new_host_map, state.fiber_host_cache)}

      candidates
      |> filter_eligible(state)
      |> sort_candidates()
      |> Enum.reduce(state, fn fiber, state_acc ->
        if available_slots(state_acc) > 0 do
          do_dispatch_fiber(state_acc, fiber)
        else
          state_acc
        end
      end)
    else
      {:error, reason} ->
        Logger.error("Poll cycle failed: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  # Discovers candidate fibers by walking <host>/.felt/ for files that carry a
  # shuttle: frontmatter block. No tag predicate — the block is the source of
  # truth, matching what Portolan's kanban already does via hasShuttleBlock.
  #
  # Returns {:ok, fibers, host_map} where:
  #   fibers   — [%{"id" => id, "status" => status}] across all hosts
  #   host_map — %{fiber_id => felt_host} for host resolution
  #
  # ## Symlink discipline
  #
  # The same physical fiber file is often reachable from multiple felt
  # hosts via symlinks. Two cases that occur in practice:
  #
  # 1. A pinned project city (`~/Documents/projects/portolan`) whose
  #    `.felt/` is a symlink into `~/loom/.felt/ai-futures/portolan/`.
  #    The same `kanban-modal.md` is reachable as `kanban-modal` (project
  #    view) and `ai-futures/portolan/kanban-modal` (loom view).
  #
  # 2. A project-canonical felt host (lightcone) whose own `.felt/` is a
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
  # - `walk_shuttle_fibers/1` skips the host entirely if `<host>/.felt/`
  #   itself is a symlink (case 1: project-cities-on-loom).
  #
  # - `do_walk_felt_dir/1` skips subdirectories that are symlinks (case 2:
  #   loom symlinking into a project-canonical host).
  #
  # The result: each physical file is enumerated by exactly one host (the
  # canonical one), and downstream `felt -C <host> show <id>` always
  # works because the host's `index.db` knows the host-relative id.
  #
  # The `file_identity` MapSet below is belt-and-suspenders for esoteric
  # cases (hard links, etc.) where two physically-distinct paths point at
  # the same inode and both pass the symlink filter.
  defp discover_candidates(state) do
    {all_fibers, host_map, _seen} =
      Enum.reduce(state.felt_hosts, {[], %{}, MapSet.new()}, fn host,
                                                                {acc_fibers, acc_map, seen} ->
        fibers_with_id = walk_shuttle_fibers(host)

        {kept, new_map, new_seen} =
          Enum.reduce(fibers_with_id, {[], %{}, seen}, fn {ident, fiber}, {fs, hm, sn} ->
            id = Map.get(fiber, "id", "")

            cond do
              ident != nil and MapSet.member?(sn, ident) ->
                # Same physical file already claimed by an earlier host.
                {fs, hm, sn}

              true ->
                next_seen = if ident, do: MapSet.put(sn, ident), else: sn
                {[fiber | fs], Map.put(hm, id, host), next_seen}
            end
          end)

        merged_map = Map.merge(new_map, acc_map)
        {acc_fibers ++ Enum.reverse(kept), merged_map, new_seen}
      end)

    {:ok, all_fibers, host_map}
  end

  # Walk <host>/.felt/ and return [{file_identity, fiber}] for each fiber
  # file physically rooted in this host (no symlink traversal). Skips the
  # host entirely if `<host>/.felt/` is itself a symlink.
  defp walk_shuttle_fibers(host) do
    felt_dir = Path.join(host, ".felt")

    case File.lstat(felt_dir) do
      {:ok, %File.Stat{type: :symlink}} ->
        # Host's .felt/ is a symlink — its content is owned by the host
        # where .felt is physically rooted. That host enumerates canonically.
        []

      _ ->
        felt_dir
        |> do_walk_felt_dir()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(fn path ->
          case parse_shuttle_fiber(host, path) do
            {:ok, fiber} -> [{file_identity(path), fiber}]
            {:error, _} -> []
          end
        end)
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

  # Parse one fiber .md file, returning {:ok, %{"id" => id, "status" => status}}
  # when the frontmatter contains a shuttle: block, {:error, _} otherwise.
  defp parse_shuttle_fiber(host, path) do
    felt_dir = Path.join(host, ".felt")
    rel = Path.relative_to(path, felt_dir)

    with {:ok, content} <- File.read(path),
         [fm] <-
           Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/ms, content,
             capture: :all_but_first
           ),
         {:ok, data} when is_map(data) <- YamlElixir.read_from_string(fm),
         shuttle when is_map(shuttle) <- Map.get(data, "shuttle") do
      fiber_id = derive_fiber_id_from_rel(rel)
      status = Map.get(data, "status", "open")
      {:ok, %{"id" => fiber_id, "status" => status}}
    else
      _ -> {:error, :no_shuttle_block}
    end
  end

  # Derive the felt fiber ID from a path relative to <host>/.felt/.
  #
  # Directory fibers:  "ai-futures/shuttle/constitution-x/constitution-x.md"
  #                    → "ai-futures/shuttle/constitution-x"
  # Bare fibers:       "some-fiber.md"
  #                    → "some-fiber"
  defp derive_fiber_id_from_rel(rel) do
    parts = Path.split(rel)

    if length(parts) >= 2 do
      basename = List.last(parts)
      dir_parts = Enum.take(parts, length(parts) - 1)
      dir_base = List.last(dir_parts)

      if String.replace_suffix(basename, ".md", "") == dir_base do
        Path.join(dir_parts)
      else
        String.replace_suffix(rel, ".md", "")
      end
    else
      String.replace_suffix(rel, ".md", "")
    end
  end

  defp filter_eligible(candidates, state) do
    Enum.filter(candidates, fn fiber -> eligible?(fiber, state) end)
  end

  defp eligible?(fiber, state) do
    status = Map.get(fiber, "status", "")
    fiber_id = Map.get(fiber, "id", "")

    # Read the shuttle: block once from disk (direct file read, no CLI spawn).
    # All per-candidate checks are derived from this single read.
    case read_fiber_shuttle_block(fiber_id, state) do
      {:ok, shuttle} ->
        cond do
          # Must have shuttle.enabled: true
          Map.get(shuttle, "enabled", false) != true ->
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

      {:error, _} ->
        false
    end
  end

  # Resolves which configured felt host owns `fiber_id`.
  #
  # Resolution order:
  # 1. State cache (fast; populated by discover_candidates/1 each poll cycle)
  # 2. Direct file-stat across each configured host's .felt/ directory
  #
  # Returns {:ok, host} for the first-configured host that contains the fiber,
  # or {:error, :not_found} when no host claims it.
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
        segments = String.split(fiber_id, "/")
        basename = List.last(segments)

        found =
          Enum.find_value(state.felt_hosts, fn host ->
            felt_dir = Path.join(host, ".felt")
            dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])
            bare_path = Path.join(felt_dir, "#{basename}.md")
            if File.exists?(dir_path) or File.exists?(bare_path), do: host, else: nil
          end)

        case found do
          nil -> {:error, :not_found}
          host -> {:ok, host}
        end
    end
  end

  # Read the shuttle: block from the fiber's .md file directly, without shelling
  # out to the felt CLI. File read + YAML parse is much faster than spawning a
  # process, making it viable for every candidate in the poll cycle.
  #
  # Uses host_for_fiber/2 to locate the right felt host across all configured
  # hosts.
  #
  # Returns {:ok, map()} when the block is present, {:error, reason} otherwise.
  defp read_fiber_shuttle_block(fiber_id, state) do
    with {:ok, host} <- host_for_fiber(fiber_id, state) do
      felt_dir = Path.join(host, ".felt")
      segments = String.split(fiber_id, "/")
      basename = List.last(segments)

      dir_path = Path.join([felt_dir | segments] ++ ["#{basename}.md"])
      bare_path = Path.join(felt_dir, "#{basename}.md")

      path =
        cond do
          File.exists?(dir_path) -> dir_path
          File.exists?(bare_path) -> bare_path
          true -> nil
        end

      if path do
        with {:ok, content} <- File.read(path),
             [fm] <-
               Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/ms, content,
                 capture: :all_but_first
               ),
             {:ok, data} when is_map(data) <- YamlElixir.read_from_string(fm),
             shuttle when is_map(shuttle) <- Map.get(data, "shuttle") do
          {:ok, shuttle}
        else
          _ -> {:error, :no_shuttle_block}
        end
      else
        {:error, :file_not_found}
      end
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

  # Returns the shuttle.agent name for a fiber, reading its block from disk.
  # Used by dispatch paths that don't already hold the block map.
  defp fetch_shuttle_agent_name(fiber_id, state) do
    case read_fiber_shuttle_block(fiber_id, state) do
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
        {:error, _} -> hd(state.felt_hosts)
      end

    with {:ok, shuttle} <- read_fiber_shuttle_block(fiber_id, state),
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
          Enum.all?(deps, fn dep_id ->
            case fetch_fiber_full(dep_id, state) do
              {:ok, dep} -> Map.get(dep, "tempered", false) == true
              {:error, _} -> false
            end
          end)
        end

      {:error, _} ->
        false
    end
  end

  defp sort_candidates(candidates) do
    Enum.sort_by(candidates, fn fiber ->
      created = Map.get(fiber, "created_at", "")
      {created, Map.get(fiber, "id", "")}
    end)
  end

  defp do_dispatch_fiber(%State{} = state, fiber) do
    fiber_id = Map.get(fiber, "id", "")

    felt_host =
      case host_for_fiber(fiber_id, state) do
        {:ok, h} -> h
        {:error, _} -> hd(state.felt_hosts)
      end

    prompt_context = dispatch_prompt_context(fiber, state)

    case Dispatcher.dispatch(
           fiber_id,
           runner: state.runner,
           work_dir: fiber_work_dir(fiber_id, state),
           prompt_context: prompt_context,
           felt_host: felt_host
         ) do
      {:ok, session} ->
        agent_name = fetch_shuttle_agent_name(fiber_id, state)
        {:ok, agent} = Shuttle.Agents.resolve_by_name(agent_name)

        # Start a watcher for this worker
        watcher_opts = [
          fiber_id: fiber_id,
          session: session,
          poller: self(),
          runner: state.runner,
          heartbeat_interval_ms: state.heartbeat_interval_ms
        ]

        case DynamicSupervisor.start_child(
               Shuttle.WatcherSupervisor,
               {WorkerWatcher, watcher_opts}
             ) do
          {:ok, watcher_pid} ->
            now = DateTime.utc_now()

            running_meta =
              %{
                pid: watcher_pid,
                session: session,
                agent_id: agent.id,
                started_at: now,
                last_activity_at: now
              }
              |> Map.merge(running_prompt_metadata(prompt_context))

            running = Map.put(state.running, fiber_id, running_meta)

            state = %{
              state
              | running: running,
                claimed: MapSet.put(state.claimed, fiber_id)
            }

            broadcast_snapshot(state)
            state

          {:error, reason} ->
            Logger.error("Failed to start watcher for #{fiber_id}: #{inspect(reason)}")

            schedule_retry(state, fiber_id, 1, %{
              error: "watcher start failed: #{inspect(reason)}"
            })
        end

      {:error, :already_running} ->
        # Session exists but we don't have a watcher — adopt it
        adopt_session(state, fiber_id)

      {:error, reason} ->
        Logger.warning("Dispatch failed for #{fiber_id}: #{inspect(reason)}")
        state
    end
  end

  # ── Reconciliation ──

  defp reconcile(%State{} = state) do
    state = reconcile_fiber_closures(state)
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
    # Find tmux sessions that exist but have no watcher
    {:ok, sessions} = list_shuttle_sessions(state)
    running_sessions = Enum.map(state.running, fn {_, meta} -> meta.session end) |> MapSet.new()

    Enum.reduce(sessions, state, fn session, state_acc ->
      if MapSet.member?(running_sessions, session) do
        state_acc
      else
        adopt_session(state_acc, session_to_fiber_id(session))
      end
    end)
  end

  defp adopt_orphans(%State{} = state) do
    {:ok, sessions} = list_shuttle_sessions(state)

    Enum.reduce(sessions, state, fn session, state_acc ->
      fiber_id = session_to_fiber_id(session)

      if Map.has_key?(state_acc.running, fiber_id) do
        state_acc
      else
        adopt_session(state_acc, fiber_id)
      end
    end)
  end

  defp adopt_session(state, fiber_id) do
    session = Dispatcher.session_name(fiber_id)

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        if Map.get(fiber, "status") != "closed" do
          agent_name = fetch_shuttle_agent_name(fiber_id, state)
          {:ok, agent} = Shuttle.Agents.resolve_by_name(agent_name)

          watcher_opts = [
            fiber_id: fiber_id,
            session: session,
            poller: self(),
            runner: state.runner,
            heartbeat_interval_ms: state.heartbeat_interval_ms
          ]

          case DynamicSupervisor.start_child(
                 Shuttle.WatcherSupervisor,
                 {WorkerWatcher, watcher_opts}
               ) do
            {:ok, watcher_pid} ->
              now = DateTime.utc_now()

              running =
                Map.put(state.running, fiber_id, %{
                  pid: watcher_pid,
                  session: session,
                  agent_id: agent.id,
                  started_at: now,
                  last_activity_at: now
                })

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

  defp handle_retry(%State{} = state, fiber_id, _retry) do
    state = release_claim(state, fiber_id)

    case fetch_fiber_full(fiber_id, state) do
      {:ok, fiber} ->
        state =
          if eligible?(fiber, state) do
            do_dispatch_fiber(state, fiber)
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

    timer_ref = Process.send_after(self(), {:retry, fiber_id, retry_token}, delay_ms)

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

    state = %{state | retry_queue: retry_queue, claimed: MapSet.put(state.claimed, fiber_id)}
    broadcast_snapshot(state)
    state
  end

  defp pop_retry(%State{} = state, fiber_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_queue, fiber_id) do
      %{retry_token: ^retry_token} = retry ->
        {:ok, retry, %{state | retry_queue: Map.delete(state.retry_queue, fiber_id)}}

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
    case state.runner.cmd("tmux", ["has-session", "-t", session], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, _} -> false
    end
  end

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
    %{
      state
      | running: Map.delete(state.running, fiber_id),
        claimed: MapSet.delete(state.claimed, fiber_id)
    }
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
      WorkerWatcher.stop(meta.pid)
    end
  end

  # Fetch a fiber's full JSON representation via the felt CLI. Routes to the
  # fiber's owning host via host_for_fiber/2 (cache → file-stat probe).
  defp fetch_fiber_full(fiber_id, state) do
    host =
      case host_for_fiber(fiber_id, state) do
        {:ok, h} -> h
        {:error, _} -> hd(state.felt_hosts)
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

  defp dispatch_prompt_context(fiber, state) do
    fiber_id = Map.get(fiber, "id", "")

    case fetch_standing_role(fiber_id, state) do
      {:ok, role} ->
        if StandingRole.standing?(role) do
          {:standing_run, StandingRole.next_run_id(role, DateTime.utc_now())}
        else
          :constitution
        end

      _ ->
        :constitution
    end
  end

  defp running_prompt_metadata({:standing_run, run_id}), do: %{state: "running", run_id: run_id}
  defp running_prompt_metadata(_), do: %{}

  defp fetch_standing_role(fiber_id, state) do
    case read_fiber_shuttle_block(fiber_id, state) do
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

  defp standing_role_snapshots(state, now) do
    with {:ok, candidates, _host_map} <- discover_candidates(state) do
      candidates
      |> Enum.filter(fn fiber ->
        standing_role?(fiber, state)
      end)
      |> Enum.flat_map(fn fiber ->
        fiber_id = Map.get(fiber, "id", "")

        case fetch_standing_role(fiber_id, state) do
          {:ok, role} ->
            [StandingRole.to_snapshot(role, now, Map.has_key?(state.running, fiber_id))]

          {:error, _} ->
            []
        end
      end)
    else
      _ -> []
    end
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

  defp list_shuttle_sessions(state) do
    case state.runner.cmd("tmux", ["ls", "-F", "\#{session_name}"], stderr_to_stdout: true) do
      {output, 0} ->
        sessions =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "shuttle-"))

        {:ok, sessions}

      {_, _} ->
        # No tmux server running
        {:ok, []}
    end
  end

  defp session_to_fiber_id("shuttle-" <> rest) do
    rest
  end

  defp session_to_fiber_id(other), do: other

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

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  # Returns the configured felt hosts list.
  #
  # Resolution:
  # 1. Env-configured hosts: LOOM_HOMES (comma-separated) → LOOM_HOME → ~/loom
  # 2. Portolan-pinned local cities from ~/.portolan/cities.json (originId="local")
  #
  # The two sources are unioned (env first, then any city paths not already
  # in env), so pinning a city in portolan auto-adds it as a felt host without
  # touching shuttle config. Remote cities (originId != "local") are skipped —
  # they belong to other machines' daemons (see constitution-shuttle-remote-dispatch).
  #
  # This is the default-fallback only; explicit :felt_hosts opts in start_link
  # take precedence via init/1 (and disable the per-poll refresh in that case).
  defp default_felt_hosts do
    env_hosts = env_felt_hosts() |> Enum.map(&Path.expand/1)
    city_hosts = portolan_city_hosts() |> Enum.map(&Path.expand/1)
    extras = Enum.reject(city_hosts, &(&1 in env_hosts))
    env_hosts ++ extras
  end

  defp env_felt_hosts do
    case System.get_env("LOOM_HOMES") do
      v when is_binary(v) and v != "" ->
        v
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        loom_home = System.get_env("LOOM_HOME")
        [if(is_binary(loom_home) and loom_home != "", do: loom_home, else: System.user_home() <> "/loom")]
    end
  end

  # Reads ~/.portolan/cities.json and returns paths for cities with
  # originId="local". Returns [] if the file is missing, malformed, or has
  # no local cities — auto-discovery is best-effort, never fatal.
  defp portolan_city_hosts do
    cities_path = Path.expand("~/.portolan/cities.json")

    with true <- File.exists?(cities_path),
         {:ok, content} <- File.read(cities_path),
         {:ok, %{"cities" => cities}} when is_list(cities) <- Jason.decode(content) do
      cities
      |> Enum.filter(fn c -> Map.get(c, "originId") == "local" end)
      |> Enum.map(fn c -> Map.get(c, "path") end)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # Re-reads default_felt_hosts/0 and updates state.felt_hosts if the list
  # changed. Called from discover_candidates/1 each poll cycle so newly-pinned
  # portolan cities pop up live. No-op when the caller passed an explicit
  # :felt_hosts opt (state.auto_discover_felt_hosts == false).
  defp refresh_felt_hosts(%{auto_discover_felt_hosts: false} = state), do: state

  defp refresh_felt_hosts(%{felt_hosts: current} = state) do
    fresh = default_felt_hosts()

    if fresh == current do
      state
    else
      Logger.info("felt_hosts updated from portolan/env: #{inspect(current)} → #{inspect(fresh)}")
      %{state | felt_hosts: fresh}
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
