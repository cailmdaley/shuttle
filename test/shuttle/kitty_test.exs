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
end
