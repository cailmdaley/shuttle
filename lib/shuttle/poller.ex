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
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias Shuttle.{Dispatcher, WorkerWatcher}

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
      :felt_host,
      :runner,
      poll_check_in_progress: false,
      running: %{},
      claimed: MapSet.new(),
      retry_queue: %{},
      waiters: %{},
      reservations: %{}
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

  # ── Server ──

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)

    felt_host = Keyword.get(opts, :felt_host, default_felt_host())
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
      felt_host: felt_host,
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

  # ── Snapshot ──

  @spec build_snapshot(State.t()) :: map()
  defp build_snapshot(state) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    eligible =
      Enum.map(state.running, fn {fiber_id, meta} ->
        %{
          fiber_id: fiber_id,
          tmux_session: meta.session,
          agent: meta.agent_id,
          state: "running",
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
      eligible: eligible,
      blocked: [],
      orphans: [],
      retrying: retrying,
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
    state = reconcile(state)

    with {:ok, candidates} <- discover_candidates(state),
         true <- available_slots(state) > 0 do
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

  defp discover_candidates(state) do
    case run_felt(state, ["ls", "-t", "constitution", "-j", "-s", "all"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fibers} when is_list(fibers) -> {:ok, fibers}
          {:ok, _} -> {:error, :invalid_felt_ls_json}
          {:error, reason} -> {:error, {:json_decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:felt_ls_failed, reason}}
    end
  end

  defp filter_eligible(candidates, state) do
    Enum.filter(candidates, fn fiber -> eligible?(fiber, state) end)
  end

  defp eligible?(fiber, state) do
    tags = Map.get(fiber, "tags", [])
    status = Map.get(fiber, "status", "")
    fiber_id = Map.get(fiber, "id", "")

    cond do
      # Must have constitution tag
      "constitution" not in tags -> false
      # Must not have draft tag
      "draft" in tags -> false
      # Must be committed to active work
      status not in ["open", "active"] -> false
      # Must not already be running
      Map.has_key?(state.running, fiber_id) -> false
      # Must not be claimed (retry queued)
      MapSet.member?(state.claimed, fiber_id) -> false
      # Dependencies must be satisfied
      true -> dependencies_satisfied?(fiber_id, state)
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

    case Dispatcher.dispatch(fiber_id, runner: state.runner, work_dir: state.felt_host) do
      {:ok, session} ->
        {:ok, agent} = Shuttle.Agents.resolve(Map.get(fiber, "tags", []))

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

            running =
              Map.put(state.running, fiber_id, %{
                pid: watcher_pid,
                session: session,
                agent_id: agent.id,
                started_at: now,
                last_activity_at: now
              })

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
          {:ok, agent} = Shuttle.Agents.resolve(Map.get(fiber, "tags", []))

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

      {_meta, running} ->
        state = %{state | running: running}

        # Re-read fiber to determine next action
        case fetch_fiber_full(fiber_id, state) do
          {:ok, fiber} ->
            status = Map.get(fiber, "status", "")

            cond do
              status == "closed" ->
                # Work complete or blocked — release claim
                release_claim(state, fiber_id)

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

  defp fetch_fiber_full(fiber_id, state) do
    case run_felt(state, ["show", fiber_id, "--json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, fiber} -> {:ok, fiber}
          {:error, _} -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_felt(state, args) do
    opts = [cd: state.felt_host, stderr_to_stdout: true]

    case state.runner.cmd("felt", args, opts) do
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

  defp default_felt_host do
    System.user_home() <> "/loom"
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
