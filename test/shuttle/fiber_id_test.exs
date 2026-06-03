defmodule Shuttle.FiberIdTest do
  use ExUnit.Case, async: true

  alias Shuttle.FiberId

  # Builds the two felt symlink topologies the canonical rule must collapse
  # uniformly, in one real on-disk tree:
  #
  #   root/
  #     loom/.felt/
  #       bare.md                                  entry-point fiber
  #       ai-futures/portolan/widget/widget.md     loom-resident nested fiber
  #       shapepipe -> root/shapepipe/.felt        loom symlinks INTO a project
  #     project/.felt -> loom/.felt/ai-futures/portolan   project symlinks INTO loom
  #     shapepipe/.felt/
  #       review-ngmix/review-ngmix.md             project-canonical store
  setup do
    root = Path.join(System.tmp_dir!(), "shuttle-fiber-id-#{System.unique_integer([:positive])}")
    loom = Path.join(root, "loom")
    project = Path.join(root, "project")
    shapepipe = Path.join(root, "shapepipe")

    write!(loom, ["bare.md"], "bare")
    write!(loom, ["ai-futures", "portolan", "widget", "widget.md"], "widget")
    write!(shapepipe, ["review-ngmix", "review-ngmix.md"], "review")

    # project/.felt → loom/.felt/ai-futures/portolan   (portolan shape)
    File.mkdir_p!(project)
    File.ln_s!(Path.join([loom, ".felt", "ai-futures", "portolan"]), Path.join(project, ".felt"))

    # loom/.felt/shapepipe → shapepipe/.felt           (shapepipe shape)
    File.ln_s!(Path.join(shapepipe, ".felt"), Path.join([loom, ".felt", "shapepipe"]))

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, loom: loom, project: project, shapepipe: shapepipe}
  end

  defp write!(store, segments, _slug) do
    dir = Path.join([store, ".felt" | Enum.drop(segments, -1)])
    File.mkdir_p!(dir)
    File.write!(Path.join([store, ".felt" | segments]), "---\nname: t\n---\n")
  end

  describe "ref_from_path/1 — the canonical rule" do
    test "loom-resident nested fiber keeps the loom-relative slug", %{loom: loom} do
      path = Path.join([loom, ".felt", "ai-futures", "portolan", "widget", "widget.md"])
      assert {:ok, %{host: host, id: "ai-futures/portolan/widget"}} = FiberId.ref_from_path(path)
      assert host == FiberId.canonical_host_path(loom)
    end

    test "entry-point fiber (slug.md directly under .felt) yields the bare slug", %{loom: loom} do
      assert {:ok, %{id: "bare"}} = FiberId.ref_from_path(Path.join([loom, ".felt", "bare.md"]))
    end

    test "portolan shape: project/.felt symlinked INTO loom resolves to the loom-relative id",
         %{loom: loom, project: project} do
      # The worker sitting in the checkout sees project-relative `widget/widget.md`,
      # but realpath collapses the symlink onto loom — host-invariant, so cross-host
      # dedup falls out for free.
      path = Path.join([project, ".felt", "widget", "widget.md"])
      assert {:ok, %{host: host, id: "ai-futures/portolan/widget"}} = FiberId.ref_from_path(path)
      assert host == FiberId.canonical_host_path(loom)
    end

    test "shapepipe shape: loom symlinking INTO a project drops the store prefix",
         %{loom: loom, shapepipe: shapepipe} do
      # This is the /state-vs-/fibers skew the constitution fixes: walking loom
      # through `loom/.felt/shapepipe → project/.felt` must yield the SAME id the
      # project-relative runtime keys — `review-ngmix`, not `shapepipe/review-ngmix`.
      via_loom = Path.join([loom, ".felt", "shapepipe", "review-ngmix", "review-ngmix.md"])
      assert {:ok, %{host: host, id: "review-ngmix"}} = FiberId.ref_from_path(via_loom)
      assert host == FiberId.canonical_host_path(shapepipe)

      # Reaching the same file through the project's own .felt agrees.
      via_project = Path.join([shapepipe, ".felt", "review-ngmix", "review-ngmix.md"])
      assert {:ok, %{id: "review-ngmix"}} = FiberId.ref_from_path(via_project)
    end

    test "a path under no .felt is not a fiber" do
      assert {:error, :no_felt_store} = FiberId.ref_from_path("/tmp/nope/widget.md")
    end

    test "a non-container .md (sibling, not <dir>/<dir>.md) is rejected", %{loom: loom} do
      sibling = Path.join([loom, ".felt", "ai-futures", "portolan", "widget", "notes.md"])
      File.write!(sibling, "x")
      assert {:error, :unexpected_layout} = FiberId.ref_from_path(sibling)
    end
  end

  describe "canonical_id/1" do
    test "returns just the slug", %{loom: loom} do
      path = Path.join([loom, ".felt", "ai-futures", "portolan", "widget", "widget.md"])
      assert {:ok, "ai-futures/portolan/widget"} = FiberId.canonical_id(path)
    end
  end
end
