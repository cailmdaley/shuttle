defmodule Shuttle.KittyTest do
  use ExUnit.Case, async: true

  alias Shuttle.Kitty

  describe "attach_command/2" do
    test "a local worker (no host) attaches with an exact tmux target" do
      assert Kitty.attach_command("shuttle-foo-bar", nil) ==
               ["tmux", "attach", "-t", "=shuttle-foo-bar"]
    end

    test "an empty host is treated as local" do
      assert Kitty.attach_command("shuttle-foo-bar", "") ==
               ["tmux", "attach", "-t", "=shuttle-foo-bar"]
    end

    test "this daemon's own host id attaches locally, not over ssh" do
      own = Shuttle.Poller.own_host_id()
      assert Kitty.attach_command("shuttle-foo-bar", own) ==
               ["tmux", "attach", "-t", "=shuttle-foo-bar"]
    end

    test "a remote host wraps the attach in ssh -tt, preserving the exact target" do
      # A host id that is not this daemon's own id is remote.
      remote = Shuttle.Poller.own_host_id() <> "-elsewhere"

      assert Kitty.attach_command("shuttle-foo-bar", remote) ==
               ["ssh", "-tt", remote, "tmux", "attach", "-t", "=shuttle-foo-bar"]
    end
  end

  describe "open/2" do
    test "rejects an empty session" do
      assert {:error, _} = Kitty.open("", "candide")
    end
  end

  describe "pick_socket/1" do
    test "prefers a normal window over a more-recent quick-access panel" do
      # The panel is newer (higher mtime) but must NOT win — a worker terminal
      # in a hide-on-focus-loss dropdown vanishes on click-away.
      candidates = [
        {"/tmp/kitty-100", 100, false},
        {"/tmp/kitty-200", 200, true}
      ]

      assert Kitty.pick_socket(candidates) == "unix:/tmp/kitty-100"
    end

    test "among normal windows the most-recently-touched wins" do
      candidates = [
        {"/tmp/kitty-100", 100, false},
        {"/tmp/kitty-300", 300, false},
        {"/tmp/kitty-200", 200, false}
      ]

      assert Kitty.pick_socket(candidates) == "unix:/tmp/kitty-300"
    end

    test "falls back to a panel when no normal window is listening" do
      candidates = [{"/tmp/kitty-200", 200, true}]
      assert Kitty.pick_socket(candidates) == "unix:/tmp/kitty-200"
    end

    test "nil when there are no sockets at all" do
      assert Kitty.pick_socket([]) == nil
    end
  end
end
