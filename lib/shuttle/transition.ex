defmodule Shuttle.Transition do
  @moduledoc """
  The unified write-plane for kanban transitions — one call that hides the
  resolve / invoke / owner-routing dance the kanban used to orchestrate itself.

  A kanban drag is `{fiber_id, target, origin}`: move this fiber to that column,
  and the fiber is owned by that host. `transition/3` turns it into a lifecycle
  mutation:

    1. **Route by origin.** The composite board (`GET /api/v1/fibers/composite`)
       stamps every fiber with the host that OWNS it. An `origin` that is this
       daemon (or absent / `"local"`) routes to the local branch; an `origin`
       matching a configured remote forwards over the tunnel; an unknown origin
       falls through to local, where the daemon's own ownership + availability
       gates are the final arbiter (mirroring Portolan's prior
       `resolveShuttleDaemonUrl` fallback).

    2. **Local branch** = resolve + invoke, in one process. `resolve_action`
       reads the daemon's own state (registry `running?` + the live felt
       document's `status`/`tempered`) to map `target` → a canonical action id;
       the same source the availability gate reads, so the resolved action is in
       the availability set by construction (the `resolve ⊆ availability`
       invariant — see `gotcha-shuttle-resolve-invoke-daemon-split`). Then the
       invoke pipeline mutates: pause/reopen/close shell the offline frontmatter
       writer, accept-run / dispatch-ad-hoc go through the in-process lifecycle.

    3. **Forward branch** = `POST <remote>/api/v1/transition` with `origin`
       omitted, so the owning daemon runs its OWN local branch against its
       authoritative state. Terminating in one hop: a fiber has exactly one
       owner, and the owner never re-forwards. No felt-store registration is
       needed — a remote only serves a fiber in its owner feed when it already
       owns the store, so the store is configured by construction.

  Both this service's `/transition` endpoint and the legacy `/actions/invoke`
  endpoint share `invoke/2` and `http_error/1`, so the invoke pipeline and its
  status mapping have a single implementation.
  """

  alias Shuttle.{Actions, FeltStores, LifecycleService, Poller, Remote}

  @default_forward_timeout_ms 30_000

  @typedoc """
  The local outcome of a transition: `{:ok, action_id}` on success, a structured
  error otherwise. The forward branch instead returns `{:forwarded, status,
  body}`, the remote daemon's verbatim response for the controller to relay.
  """
  @type result ::
          {:ok, String.t()}
          | {:forwarded, non_neg_integer(), map()}
          | {:error, term()}

  @doc """
  Resolve `target` to an action and invoke it on the fiber's owning daemon.

  Returns `{:ok, action_id}` for a local transition, `{:forwarded, status,
  body}` for one relayed to a remote owner, or `{:error, reason}` (map reasons
  to HTTP via `http_error/1`).
  """
  @spec transition(String.t(), String.t(), String.t() | nil, keyword()) :: result()
  def transition(fiber_id, target, origin, opts \\ []) do
    case route(origin, opts) do
      :local -> transition_local(fiber_id, target)
      {:remote, %Remote{} = remote} -> forward(remote, fiber_id, target, origin, opts)
    end
  end

  # ── Routing ──

  defp route(origin, opts) do
    own = Keyword.get(opts, :own_host_id) || Poller.own_host_id()

    cond do
      origin in [nil, "", "local", own] ->
        :local

      true ->
        case find_remote(origin, opts) do
          %Remote{} = remote -> {:remote, remote}
          # Unknown origin: the local daemon is the final arbiter. If it owns the
          # fiber it acts; if not, its availability gate returns a clean error
          # rather than a silent mis-route.
          nil -> :local
        end
    end
  end

  defp find_remote(origin, opts) do
    opts
    |> Keyword.get(:remotes, Application.get_env(:shuttle, :remotes, []))
    |> Remote.from_config_list()
    |> Enum.find(&(&1.name == origin))
  end

  # ── Local branch: resolve + invoke ──

  defp transition_local(fiber_id, target) do
    case Poller.resolve_action(fiber_id, target) do
      {:ok, %{id: action_id}} ->
        with :ok <- invoke(fiber_id, action_id), do: {:ok, action_id}

      {:error, :unknown_target} ->
        {:error, :unknown_target}

      # Any other resolve failure is an unresolvable fiber (unknown id,
      # unreadable frontmatter, foreign store) — the read paths 404 it, so match
      # them rather than falling to the catch-all 500.
      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @doc """
  The invoke pipeline: validate the action id, confirm it is available for the
  fiber right now, then perform the mutation. Shared with `/actions/invoke`.
  """
  @spec invoke(String.t(), String.t()) :: :ok | {:error, term()}
  def invoke(fiber_id, action) do
    with :ok <- validate_action(action),
         {:ok, host} <- validate_available(fiber_id, action) do
      invoke_action(fiber_id, action, host)
    end
  end

  defp validate_action(action) do
    if Actions.known_action?(action), do: :ok, else: {:error, :unknown_action}
  end

  # Action availability is resolved by the Poller, which overlays the
  # daemon-owned runtime lifecycle. Reading availability anywhere else — e.g.
  # parsing the frontmatter here — sees the default review state and wrongly
  # rejects valid standing-role transitions (accept-run) as
  # `action_not_available`. The host is resolved separately for the shuttle-ctl
  # verbs that still shell out (close / pause / reopen).
  defp validate_available(fiber_id, action) do
    case Poller.actions_for(fiber_id) do
      {:ok, actions} ->
        if Enum.any?(actions, &(Map.get(&1, :id) == action || Map.get(&1, "id") == action)) do
          host_for_fiber(fiber_id)
        else
          {:error, :action_not_available}
        end

      # actions_for failed to resolve/read the fiber (unknown id, unreadable
      # frontmatter, foreign felt-store path). The read paths (show / resolve)
      # map this to 404; normalize it to :not_found so invoke matches them
      # instead of the catch-all 500.
      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # Resolve the felt store owning `fiber_id` (so shuttle-ctl verbs get the right
  # `--felt-store`) by asking felt for the carried path — the same resolution
  # /api/v1/fibers uses, so it never disagrees with the id we advertised.
  defp host_for_fiber(fiber_id), do: FeltStores.host_for_fiber(fiber_id)

  # pause / reopen / close shell the Go frontmatter writer with
  # SHUTTLE_LIFECYCLE_OFFLINE so it writes frontmatter only (status, tempered,
  # closed-at) WITHOUT calling back into this daemon's /api/v1/lifecycle. The
  # document carries the entire lifecycle (status + tempered) — there is no
  # runtime row to reset, so close/reopen are a single felt write and
  # re-arm/awaiting are recomputed from the document on the next poll.
  defp invoke_action(fiber_id, "pause", host), do: run_offline(["pause", fiber_id], host)

  defp invoke_action(fiber_id, "reopen", host), do: run_offline(["reopen", fiber_id], host)

  # accept-run goes through the in-process lifecycle path so the felt-document
  # re-arm happens atomically against poll cycles, not the Go `shuttle-ctl
  # accept` (which can race a concurrent poll's document read).
  defp invoke_action(fiber_id, "accept-run", _host) do
    case LifecycleService.accept(fiber_id) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:command_error, 1, reason}}
    end
  end

  defp invoke_action(fiber_id, "close-awaiting-review", host),
    do: run_offline(["close", fiber_id], host)

  defp invoke_action(fiber_id, "close-tempered", host),
    do: run_offline(["close", fiber_id, "--tempered=true"], host)

  defp invoke_action(fiber_id, "close-composted", host),
    do: run_offline(["close", fiber_id, "--tempered=false"], host)

  defp invoke_action(fiber_id, "dispatch-ad-hoc", _host) do
    case Poller.dispatch_fiber(Poller, fiber_id, force: true, ad_hoc: true) do
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_offline(args, nil), do: run_cmd(args, lifecycle_offline_env())

  defp run_offline(args, host) when is_binary(host),
    do: run_cmd(["--felt-store", host | args], lifecycle_offline_env())

  defp lifecycle_offline_env, do: [{"SHUTTLE_LIFECYCLE_OFFLINE", "1"}]

  defp run_cmd(args, env) do
    case System.cmd("shuttle-ctl", args, stderr_to_stdout: true, env: env) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:command_error, status, output}}
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  # ── Forward branch: relay to the owning remote daemon ──

  defp forward(%Remote{} = remote, fiber_id, target, origin, opts) do
    client = Keyword.get(opts, :client) || forward_client()
    timeout = Keyword.get(opts, :forward_timeout_ms, @default_forward_timeout_ms)
    url = transition_url(remote)
    payload = Jason.encode!(%{fiber_id: fiber_id, target: target})

    case client.post(url, payload, "application/json", timeout) do
      {:ok, status, body} ->
        # Re-stamp origin with what the caller sent: the remote computed its own
        # response treating the fiber as local, so its `origin` would read
        # "local"/its own id. The kanban always sees the origin it routed to.
        {:forwarded, status, Map.put(decode_body(body), "origin", origin)}

      {:error, reason} ->
        {:error, {:forward_failed, remote.name, reason}}
    end
  end

  defp transition_url(%Remote{url: url}) do
    url
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v1/transition")
  end

  defp forward_client do
    Application.get_env(:shuttle, :transition_client, Shuttle.RemoteRegistry.Client.Default)
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{"error" => body}
    end
  end

  defp decode_body(_), do: %{}

  # ── HTTP status mapping (shared by both controllers) ──

  @doc """
  Map a transition/invoke error reason to an `{http_status, error_string}` pair.
  The single place the write-plane's error vocabulary becomes HTTP.
  """
  @spec http_error(term()) :: {non_neg_integer(), String.t()}
  def http_error(:unknown_target), do: {400, "unknown_target"}
  def http_error(:unknown_action), do: {400, "unknown_action"}
  def http_error(:action_not_available), do: {409, "action_not_available"}
  def http_error(:already_running), do: {409, "already_running"}
  def http_error(:not_found), do: {404, "not_found"}

  def http_error({:command_error, status, output}),
    do: {422, "shuttle exited #{status}: #{String.trim(output)}"}

  def http_error({:forward_failed, remote, reason}),
    do: {502, "forward to #{remote} failed: #{render_error(reason)}"}

  def http_error(reason), do: {500, render_error(reason)}

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason) when is_atom(reason), do: to_string(reason)
  defp render_error(reason), do: inspect(reason)
end
