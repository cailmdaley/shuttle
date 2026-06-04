defmodule Shuttle.FeltStoresTest do
  use ExUnit.Case, async: false

  alias Shuttle.FeltStores

  setup do
    prev = System.get_env("LOOM_HOMES")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("LOOM_HOMES")
        v -> System.put_env("LOOM_HOMES", v)
      end
    end)

    :ok
  end

  describe "host_for_fiber/1" do
    test "resolves a loom-resident fiber by its full store-relative slug" do
      loom = tmp_dir()
      write_fiber(Path.join(loom, ".felt"), ["ai-futures", "portolan", "debug"])
      System.put_env("LOOM_HOMES", loom)

      assert {:ok, host} = FeltStores.host_for_fiber("ai-futures/portolan/debug")
      assert Path.expand(host) == Path.expand(loom)
    end

    test "does NOT match a nested loom fiber by its bare leaf (canonical id is the full slug)" do
      loom = tmp_dir()
      # Canonical id of this file is "a/b" — NOT "b".
      write_fiber(Path.join(loom, ".felt"), ["a", "b"])
      System.put_env("LOOM_HOMES", loom)

      assert {:ok, _} = FeltStores.host_for_fiber("a/b")
      assert {:error, :not_found} = FeltStores.host_for_fiber("b")
    end

    # The candide topology: a project's .felt symlinked into loom as a sub-path.
    # The canonical id is the bare leaf (realpath lands in the project's .felt),
    # while the file is reachable under loom only via the symlinked prefix. This
    # is the case the old naive path construction 400'd on; it also proves the
    # glob-by-leaf fallback descends through the symlink.
    test "resolves a project-resident (prefix-drop) fiber by its bare-leaf canonical id" do
      loom = tmp_dir()
      project = tmp_dir()
      File.mkdir_p!(Path.join(loom, ".felt"))
      write_fiber(Path.join(project, ".felt"), ["review-ngmix-v2-pr740"])
      File.ln_s!(Path.join(project, ".felt"), Path.join([loom, ".felt", "shapepipe"]))
      System.put_env("LOOM_HOMES", loom)

      assert {:ok, host} = FeltStores.host_for_fiber("review-ngmix-v2-pr740")
      assert Path.expand(host) == Path.expand(loom)
    end

    test "returns :not_found for an unknown fiber" do
      loom = tmp_dir()
      File.mkdir_p!(Path.join(loom, ".felt"))
      System.put_env("LOOM_HOMES", loom)

      assert {:error, :not_found} = FeltStores.host_for_fiber("does-not-exist")
    end
  end

  defp write_fiber(felt_dir, slug_segments) do
    leaf = List.last(slug_segments)
    dir = Path.join([felt_dir | slug_segments])
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{leaf}.md")
    File.write!(path, "---\nname: #{leaf}\n---\n\nBody.\n")
    path
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "felt_stores_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
