defmodule Shuttle.RemoteRegistryTest do
  use ExUnit.Case

  alias Shuttle.Remote
  alias Shuttle.RemoteRegistry

  # ── Mock Client ──
  #
  # A deterministic stub for the HTTP transport. Tests script per-URL
  # responses (success body, error reason) so we can drive happy-path,
  # transient-failure, and stale paths without spinning up a Bandit
  # endpoint or stubbing :httpc directly.

  defmodule MockClient do
    @behaviour Shuttle.RemoteRegistry.Client

    use Agent

    def start_link(_ \\ []) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def set(url, response), do: Agent.update(__MODULE__, &Map.put(&1, url, response))

    @impl true
    def get(url, _timeout_ms) do
      Agent.get(__MODULE__, &Map.get(&1, url, {:error, :not_set}))
    end
  end

  setup do
    start_supervised!(MockClient)
    MockClient.reset()
    :ok
  end

  defp candide_remote(opts \\ []) do
    %Remote{
      name: "candide",
      url: "http://localhost:4001",
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 50),
      request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 100),
      stale_multiplier: Keyword.get(opts, :stale_multiplier, 2)
    }
  end

  defp snapshot_with_running(fiber_ids) do
    Jason.encode!(%{
      "host" => "candide",
      "eligible" => Enum.map(fiber_ids, &%{"fiber_id" => &1}),
      "blocked" => [],
      "retrying" => []
    })
  end

  # ── Remote struct ──

  describe "Remote.from_config/1" do
    test "parses a complete map" do
      r =
        Remote.from_config(%{
          name: "candide",
          url: "http://localhost:4001",
          poll_interval_ms: 3000
        })

      assert r.name == "candide"
      assert r.url == "http://localhost:4001"
      assert r.poll_interval_ms == 3000
      # Default still applies for fields not provided
      assert r.request_timeout_ms == 2000
    end

    test "accepts string keys" do
      r = Remote.from_config(%{"name" => "candide", "url" => "http://localhost:4001"})
      assert r.name == "candide"
    end

    test "accepts keyword list" do
      r = Remote.from_config(name: "candide", url: "http://localhost:4001")
      assert r.name == "candide"
    end

    test "returns nil when name is missing" do
      assert Remote.from_config(%{url: "http://localhost:4001"}) == nil
    end

    test "returns nil when url is missing" do
      assert Remote.from_config(%{name: "candide"}) == nil
    end
  end

  describe "Remote.stale?/3" do
    test "nil last_polled_at is always stale" do
      assert Remote.stale?(candide_remote(), nil, DateTime.utc_now())
    end

    test "fresh poll within threshold is not stale" do
      now = DateTime.utc_now()
      recent = DateTime.add(now, -10, :millisecond)
      remote = candide_remote(poll_interval_ms: 100)
      refute Remote.stale?(remote, recent, now)
    end

    test "old poll past 2× threshold is stale" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -300, :millisecond)
      remote = candide_remote(poll_interval_ms: 100, stale_multiplier: 2)
      assert Remote.stale?(remote, old, now)
    end
  end

  # ── RemoteRegistry happy path ──

  describe "registry polling" do
    test "polls configured remote and exposes the snapshot" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:ok, snapshot_with_running(["work/foo"])}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_happy,
          remotes: [candide_remote()],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_happy)

      snapshots = RemoteRegistry.snapshots(:reg_happy)
      assert Map.has_key?(snapshots, "candide")

      candide = snapshots["candide"]
      refute candide.stale
      assert is_struct(candide.last_polled_at, DateTime)
      assert candide.last_error == nil
      assert get_in(candide, [:snapshot, "host"]) == "candide"
    end

    test "running_fibers/0 returns the union of running across fresh remotes" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:ok, snapshot_with_running(["work/a", "work/b"])}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_running,
          remotes: [candide_remote()],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_running)

      running = RemoteRegistry.running_fibers(:reg_running)
      assert MapSet.member?(running, "work/a")
      assert MapSet.member?(running, "work/b")
      refute MapSet.member?(running, "work/c")
    end

    test "origin_for_running/1 returns the remote name claiming a fiber" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:ok, snapshot_with_running(["work/foo"])}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_origin,
          remotes: [candide_remote()],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_origin)

      assert RemoteRegistry.origin_for_running(:reg_origin, "work/foo") == "candide"
      assert RemoteRegistry.origin_for_running(:reg_origin, "work/missing") == nil
    end
  end

  # ── Failure paths ──

  describe "transient failures" do
    test "non-200 response marks the remote stale with last_error set" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:error, {:http_status, 502}}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_502,
          remotes: [candide_remote()],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_502)

      candide = RemoteRegistry.snapshot(:reg_502, "candide")
      assert candide.stale
      assert candide.last_error == {:http_status, 502}
      # No fiber claims when the remote has nothing to report.
      assert RemoteRegistry.running_fibers(:reg_502) == MapSet.new()
    end

    test "connection error marks the remote stale" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:error, :econnrefused}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_refused,
          remotes: [candide_remote()],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_refused)

      candide = RemoteRegistry.snapshot(:reg_refused, "candide")
      assert candide.stale
      assert candide.last_error == :econnrefused
    end

    test "malformed JSON marks the remote stale" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:ok, "not json {"}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_garbage,
          remotes: [candide_remote()],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_garbage)

      candide = RemoteRegistry.snapshot(:reg_garbage, "candide")
      assert candide.stale
      assert candide.last_error == :malformed_json
    end
  end

  # ── Staleness derivation ──

  describe "staleness derivation" do
    test "fresh poll, then long enough wait, becomes stale" do
      MockClient.set(
        "http://localhost:4001/api/v1/state",
        {:ok, snapshot_with_running(["work/temp"])}
      )

      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_stale,
          # Tiny intervals so the test runs fast. stale = 2 × 50ms = 100ms.
          remotes: [candide_remote(poll_interval_ms: 50, stale_multiplier: 2)],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      :ok = RemoteRegistry.poll_now(:reg_stale)

      # Right after polling, fresh + running.
      refute RemoteRegistry.snapshot(:reg_stale, "candide").stale
      assert MapSet.member?(RemoteRegistry.running_fibers(:reg_stale), "work/temp")

      # After 2 × poll_interval, the snapshot is stale and running_fibers
      # drops it (the safety valve so a permanently disconnected remote
      # doesn't permanently block local dispatch).
      Process.sleep(120)

      assert RemoteRegistry.snapshot(:reg_stale, "candide").stale
      refute MapSet.member?(RemoteRegistry.running_fibers(:reg_stale), "work/temp")
    end
  end

  # ── No remotes configured ──

  describe "no remotes" do
    test "running_fibers/0 returns empty MapSet" do
      {:ok, _pid} =
        RemoteRegistry.start_link(
          name: :reg_empty,
          remotes: [],
          client: MockClient,
          tick_interval_ms: 60_000
        )

      assert RemoteRegistry.running_fibers(:reg_empty) == MapSet.new()
      assert RemoteRegistry.snapshots(:reg_empty) == %{}
    end
  end

  # ── Module fallback when registry isn't running ──

  describe "graceful absence" do
    test "running_fibers/0 returns empty MapSet when registry is not started" do
      # Use a name we know isn't registered.
      assert RemoteRegistry.running_fibers(:reg_does_not_exist) == MapSet.new()
      assert RemoteRegistry.snapshot(:reg_does_not_exist, "candide") == nil
      assert RemoteRegistry.origin_for_running(:reg_does_not_exist, "x") == nil
    end
  end
end
