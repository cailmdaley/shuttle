defmodule Shuttle.OriginRouter do
  @moduledoc """
  Owner-routing for the kanban write plane — the single forwarder behind every
  write endpoint.

  Every kanban mutation targets a fiber owned by exactly one daemon. The
  composite board (`GET /api/v1/fibers/composite`) stamps each fiber with its
  owning `origin`; a write carries that origin back so the local daemon can
  either act (origin is itself) or forward to the owning remote over the SSH
  tunnel. `/transition`, `/felt-edit`, `/lifecycle`, `/felt-history`, and
  `/dispatch` all route through here, so owner-routing has ONE implementation
  that cannot drift per-verb (the same discipline `Shuttle.Transition` keeps for
  `invoke/2` + `http_error/1`).

    * `route/2` decides local vs remote from the carried origin.
    * `forward/4` relays a POST to the owning remote's identical path with
      `origin` omitted, returning the remote's verbatim `{:forwarded, status,
      body}` so the caller can relay it.

  Terminating in one hop: a fiber has exactly one owner, and the owner runs the
  forwarded request as local (its origin is `nil` after stripping), so it never
  re-forwards. No felt-store registration is needed in the forward — a remote
  only serves a fiber in its owner feed when it already owns the store, so the
  store is configured by construction by the time the kanban can route to it.

  **Safety:** an `origin` that matches no configured remote falls through to
  `:local`, where the endpoint's own resolution is the final arbiter — a
  mis-stamped origin degrades to a clean local "fiber not found" / availability
  error, never a silent wrong-host write.
  """

  alias Shuttle.{Poller, Remote}

  @default_forward_timeout_ms 30_000

  @typedoc """
  Where a write should execute: `:local` runs the endpoint's own handler here;
  `{:remote, remote}` forwards to the owning daemon.
  """
  @type route_decision :: :local | {:remote, Remote.t()}

  @doc """
  Decide whether a write for a fiber stamped with `origin` runs locally or
  forwards to a remote owner.

  `nil` / `""` / `"local"` / this daemon's own host id → `:local`. An origin
  matching a configured remote → `{:remote, remote}`. Any other (unknown)
  origin → `:local`, where the endpoint's own resolution arbitrates.

  Opts (for tests / explicit wiring): `:own_host_id`, `:remotes`.
  """
  @spec route(String.t() | nil, keyword()) :: route_decision()
  def route(origin, opts \\ []) do
    own = Keyword.get(opts, :own_host_id) || Poller.own_host_id()

    cond do
      origin in [nil, "", "local", own] ->
        :local

      true ->
        case find_remote(origin, opts) do
          %Remote{} = remote -> {:remote, remote}
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

  @doc """
  Forward a write to the owning remote daemon's identical `path` (e.g.
  `"/api/v1/felt-edit"`). `payload` is the request body map; the `origin` key is
  stripped (string or atom) before sending, so the owner treats the fiber as
  local and runs its own handler.

  Returns `{:forwarded, status, body}` — the remote's verbatim response for the
  caller to relay — or `{:error, {:forward_failed, name, reason}}` when the
  tunnel POST fails. The body is left as the remote sent it (text or JSON); a
  caller that needs to rewrite it (e.g. `Shuttle.Transition` re-stamping
  `origin`) does so on top of this.

  Opts: `:client` (transport stub), `:forward_timeout_ms`.
  """
  @spec forward(Remote.t(), String.t(), map(), keyword()) ::
          {:forwarded, non_neg_integer(), String.t()} | {:error, term()}
  def forward(%Remote{} = remote, path, payload, opts \\ []) when is_map(payload) do
    client = Keyword.get(opts, :client) || forward_client()
    timeout = Keyword.get(opts, :forward_timeout_ms, @default_forward_timeout_ms)
    url = remote_url(remote, path)
    body = payload |> Map.delete("origin") |> Map.delete(:origin) |> Jason.encode!()

    case client.post(url, body, "application/json", timeout) do
      {:ok, status, resp} -> {:forwarded, status, resp}
      {:error, reason} -> {:error, {:forward_failed, remote.name, reason}}
    end
  end

  defp remote_url(%Remote{url: url}, path) do
    String.trim_trailing(url, "/") <> path
  end

  # The write-plane forward transport. One config key for every write endpoint's
  # cross-host POST, so a test stubs the whole forward plane at a single point.
  defp forward_client do
    Application.get_env(:shuttle, :write_forward_client, Shuttle.RemoteRegistry.Client.Default)
  end
end
