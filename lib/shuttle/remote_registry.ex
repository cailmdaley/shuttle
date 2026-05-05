defmodule Shuttle.RemoteRegistry do
  @moduledoc """
  Polls each configured remote Shuttle daemon's `GET /api/v1/state`
  endpoint and caches the snapshot per origin.

  The laptop's local Shuttle daemon uses this registry to:

    * **Defer dispatch** for fibers a fresh remote snapshot already
      lists as running. The deferral check reads
      `running_fibers/0` (an `O(1)` `MapSet` lookup).

    * **Composite snapshot** — `Shuttle.Web.StateController` returns
      the local snapshot plus per-origin remote snapshots so the
      kanban frontend has cross-host visibility.

  Snapshot pull is fire-and-forget polling: the remote daemon doesn't
  know it's being polled, no persistent connections, no auth state.
  Failures (network, non-200, malformed JSON) only mark the origin as
  "haven't heard from them recently"; the registry never crashes and
  the deferral safety valve lifts after `stale_multiplier ×
  poll_interval_ms`.

  ## Configuration

      config :shuttle, :remotes, [
        %{name: "candide", url: "http://localhost:4001", poll_interval_ms: 5000}
      ]

  See `Shuttle.Remote` for the full config shape. The registry boots
  with no remotes by default — local-only setups pay nothing.

  ## Test injection

  The HTTP transport is a behaviour (`Shuttle.RemoteRegistry.Client`)
  so tests can substitute a deterministic stub without spinning up a
  real Bandit endpoint or stubbing `:httpc`. The default client wraps
  `:httpc`.
  """

  use GenServer
  require Logger

  alias Shuttle.Remote

  @pubsub_topic "shuttle:remotes"

  defmodule State do
    @moduledoc false
    defstruct [
      :remotes,
      :client,
      :tick_timer_ref,
      :tick_interval_ms,
      snapshots: %{}
    ]
  end

  # ── Client ──

  @doc """
  Starts the registry. Accepts:

    * `:remotes` — list of `%Shuttle.Remote{}` (or maps/keyword lists
      that `Shuttle.Remote.from_config/1` understands). Defaults to
      `Application.get_env(:shuttle, :remotes, [])`.
    * `:client` — module implementing `Shuttle.RemoteRegistry.Client`.
      Defaults to `Shuttle.RemoteRegistry.Client.Default` (`:httpc`).
    * `:tick_interval_ms` — how often the registry tick runs. Each
      tick polls every remote whose `last_polled_at` is older than
      its `poll_interval_ms`. Defaults to 1_000.
    * `:name` — GenServer name. Defaults to `__MODULE__`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the cached snapshot map for every configured remote, keyed
  by remote name. Each value carries `:snapshot`, `:last_polled_at`,
  `:stale`, and `:last_error` (when present).

  An empty map means no remotes are configured (or the registry isn't
  running — callers tolerate this for graceful degradation).
  """
  @spec snapshots() :: %{String.t() => map()}
  def snapshots, do: snapshots(__MODULE__)

  @spec snapshots(GenServer.server()) :: %{String.t() => map()}
  def snapshots(server) do
    if registry_alive?(server) do
      GenServer.call(server, :snapshots)
    else
      %{}
    end
  end

  @doc """
  Returns one cached snapshot or `nil` when the remote isn't
  configured.
  """
  @spec snapshot(String.t()) :: map() | nil
  def snapshot(name), do: snapshot(__MODULE__, name)

  @spec snapshot(GenServer.server(), String.t()) :: map() | nil
  def snapshot(server, name) do
    if registry_alive?(server) do
      GenServer.call(server, {:snapshot, name})
    else
      nil
    end
  end

  @doc """
  Returns the union of `fiber_id`s currently running across all
  *fresh* remote snapshots. Stale snapshots are excluded — that's the
  safety valve so a permanently-disconnected remote doesn't
  permanently block local dispatch.

  Used by `Shuttle.Poller` for the deferral check; an `O(1)`
  `MapSet.member?/2` keeps the dispatch path cheap.

  When the registry isn't running (test fixtures, no remotes
  configured), returns an empty `MapSet`.
  """
  @spec running_fibers() :: MapSet.t()
  def running_fibers, do: running_fibers(__MODULE__)

  @spec running_fibers(GenServer.server()) :: MapSet.t()
  def running_fibers(server) do
    if registry_alive?(server) do
      GenServer.call(server, :running_fibers)
    else
      MapSet.new()
    end
  end

  @doc """
  Returns the origin (remote name) that claims `fiber_id` as running,
  or `nil` when no fresh remote claims it. Used by the Poller to log
  `deferring to <origin>` and to populate `blocked` snapshot entries.
  """
  @spec origin_for_running(String.t()) :: String.t() | nil
  def origin_for_running(fiber_id), do: origin_for_running(__MODULE__, fiber_id)

  @spec origin_for_running(GenServer.server(), String.t()) :: String.t() | nil
  def origin_for_running(server, fiber_id) do
    if registry_alive?(server) do
      GenServer.call(server, {:origin_for_running, fiber_id})
    else
      nil
    end
  end

  @doc """
  Forces a synchronous poll cycle. Returns when every remote has
  been probed once. Used by tests to deterministically drive the
  registry.
  """
  @spec poll_now() :: :ok
  def poll_now, do: poll_now(__MODULE__)

  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server) do
    GenServer.call(server, :poll_now)
  end

  defp registry_alive?(server) do
    case GenServer.whereis(server) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # ── Server ──

  @impl true
  def init(opts) do
    remotes =
      opts
      |> Keyword.get(:remotes, Application.get_env(:shuttle, :remotes, []))
      |> normalize_remotes()

    client = Keyword.get(opts, :client, Shuttle.RemoteRegistry.Client.Default)
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, 1_000)

    Logger.info("RemoteRegistry: configured #{length(remotes)} remote(s): " <>
                  inspect(Enum.map(remotes, & &1.name)))

    snapshots =
      Map.new(remotes, fn remote ->
        {remote.name,
         %{
           snapshot: nil,
           last_polled_at: nil,
           stale: true,
           last_error: nil,
           remote: remote
         }}
      end)

    state = %State{
      remotes: remotes,
      client: client,
      tick_interval_ms: tick_interval_ms,
      snapshots: snapshots
    }

    state =
      if remotes == [] do
        state
      else
        # Schedule the first tick immediately so we don't wait
        # tick_interval_ms before the first poll.
        schedule_tick(state, 0)
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshots, _from, state) do
    {:reply, build_snapshots_view(state), state}
  end

  def handle_call({:snapshot, name}, _from, state) do
    {:reply, build_one_view(state, name), state}
  end

  def handle_call(:running_fibers, _from, state) do
    {:reply, build_running_fibers(state), state}
  end

  def handle_call({:origin_for_running, fiber_id}, _from, state) do
    {:reply, find_origin(state, fiber_id), state}
  end

  def handle_call(:poll_now, _from, state) do
    state = poll_all(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tick, _token}, state) do
    state = poll_all(state)
    state = schedule_tick(state, state.tick_interval_ms)
    broadcast(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Polling ──

  defp poll_all(%State{remotes: remotes, client: client} = state) do
    now = DateTime.utc_now()
    now_ms = DateTime.to_unix(now, :millisecond)

    new_snapshots =
      Enum.reduce(remotes, state.snapshots, fn remote, acc ->
        prev = Map.get(acc, remote.name, %{remote: remote})

        if should_poll?(prev, remote, now_ms) do
          fetched = fetch_one(remote, client, now, prev)

          Map.put(acc, remote.name, fetched)
        else
          acc
        end
      end)

    %{state | snapshots: new_snapshots}
  end

  # `should_poll?` gates the next attempt on `last_attempt_at` (we tried
  # recently — back off) rather than `last_polled_at` (last *success*).
  # That way a permanently-down remote is retried at the configured
  # cadence without burning every tick.
  defp should_poll?(%{last_attempt_at: %DateTime{} = last}, remote, now_ms) do
    last_ms = DateTime.to_unix(last, :millisecond)
    now_ms - last_ms >= remote.poll_interval_ms
  end

  defp should_poll?(_, _remote, _now_ms), do: true

  defp fetch_one(%Remote{} = remote, client, now, prev) do
    url = Remote.state_url(remote)

    case client.get(url, remote.request_timeout_ms) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, snapshot} when is_map(snapshot) ->
            # Successful read — refresh both timestamps.
            %{
              snapshot: snapshot,
              last_polled_at: now,
              last_attempt_at: now,
              stale: false,
              last_error: nil,
              remote: remote
            }

          _ ->
            Logger.debug("RemoteRegistry: malformed JSON from #{remote.name}")

            failure_entry(remote, prev, now, :malformed_json)
        end

      {:error, reason} ->
        Logger.debug("RemoteRegistry: poll failed for #{remote.name}: #{inspect(reason)}")

        failure_entry(remote, prev, now, reason)
    end
  end

  # A failed attempt updates `last_attempt_at` (so the polling cadence
  # backs off) and `last_error` (so the operator can see what's
  # broken), but preserves `last_polled_at` and the prior `snapshot` —
  # those reflect the last *successful* read. Staleness is derived from
  # `last_polled_at` so a stretch of failures eventually trips the
  # safety valve, lifting any local-poller deferrals built on this
  # remote.
  defp failure_entry(remote, prev, now, reason) do
    %{
      snapshot: Map.get(prev, :snapshot),
      last_polled_at: Map.get(prev, :last_polled_at),
      last_attempt_at: now,
      stale: true,
      last_error: reason,
      remote: remote
    }
  end

  # ── Views ──

  defp build_snapshots_view(%State{} = state) do
    now = DateTime.utc_now()

    Map.new(state.snapshots, fn {name, entry} ->
      {name, view_entry(entry, now)}
    end)
  end

  defp build_one_view(%State{} = state, name) do
    case Map.get(state.snapshots, name) do
      nil -> nil
      entry -> view_entry(entry, DateTime.utc_now())
    end
  end

  defp view_entry(%{remote: remote} = entry, now) do
    %{
      snapshot: entry.snapshot,
      last_polled_at: entry.last_polled_at,
      stale: Remote.stale?(remote, entry.last_polled_at, now),
      last_error: entry.last_error
    }
  end

  defp build_running_fibers(%State{} = state) do
    now = DateTime.utc_now()

    state.snapshots
    |> Enum.reduce(MapSet.new(), fn {_name, entry}, acc ->
      if not Remote.stale?(entry.remote, entry.last_polled_at, now) and is_map(entry.snapshot) do
        ids = running_ids_in_snapshot(entry.snapshot)
        Enum.reduce(ids, acc, &MapSet.put(&2, &1))
      else
        acc
      end
    end)
  end

  defp find_origin(%State{} = state, fiber_id) do
    now = DateTime.utc_now()

    Enum.find_value(state.snapshots, fn {name, entry} ->
      if not Remote.stale?(entry.remote, entry.last_polled_at, now) and is_map(entry.snapshot) do
        if MapSet.member?(running_ids_in_snapshot(entry.snapshot), fiber_id), do: name
      end
    end)
  end

  # The remote daemon's snapshot lists active workers under "eligible" (a
  # somewhat-confusing legacy name; see Poller.build_snapshot/1 — the field
  # carries currently-running workers, not eligibility candidates).
  defp running_ids_in_snapshot(snapshot) do
    snapshot
    |> Map.get("eligible", [])
    |> Enum.map(&Map.get(&1, "fiber_id", ""))
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  # ── Tick scheduling ──

  defp schedule_tick(%State{} = state, delay_ms) do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, token}, delay_ms)
    %{state | tick_timer_ref: timer_ref}
  end

  defp broadcast(%State{} = state) do
    if Process.whereis(Shuttle.PubSub) do
      Phoenix.PubSub.broadcast(
        Shuttle.PubSub,
        @pubsub_topic,
        {:remote_snapshots, build_snapshots_view(state)}
      )
    end

    :ok
  end

  # ── Config normalization ──

  defp normalize_remotes(entries) do
    Enum.flat_map(entries, fn
      %Remote{} = r -> [r]
      other -> List.wrap(Remote.from_config(other))
    end)
  end
end

defmodule Shuttle.RemoteRegistry.Client do
  @moduledoc """
  Behaviour for remote daemon HTTP fetches. Default implementation
  wraps `:httpc`; tests substitute a stub via the `:client` opt.
  """

  @callback get(url :: String.t(), timeout_ms :: non_neg_integer()) ::
              {:ok, body :: String.t()} | {:error, term()}
end

defmodule Shuttle.RemoteRegistry.Client.Default do
  @moduledoc false
  @behaviour Shuttle.RemoteRegistry.Client

  @impl true
  def get(url, timeout_ms) when is_binary(url) and is_integer(timeout_ms) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    request = {String.to_charlist(url), []}
    http_opts = [{:timeout, timeout_ms}, {:connect_timeout, timeout_ms}]

    case :httpc.request(:get, request, http_opts, []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        body_str = if is_list(body), do: List.to_string(body), else: body
        {:ok, body_str}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end
end
