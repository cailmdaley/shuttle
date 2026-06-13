defmodule Shuttle.Kitty do
  @moduledoc """
  Open a worker's tmux session in a kitty tab on THIS machine.

  The standalone Shuttle UI is a browser app, so — unlike Portolan's native
  shell — it can't open a terminal itself. The daemon does it instead, via
  kitty's remote-control CLI (`kitty @ launch`). This is deliberately **not**
  owner-routed: the tab must appear where the human's browser is (the machine
  serving the UI), never on a headless cluster. A local-owned worker attaches
  directly; a remote-owned worker opens a *local* tab that `ssh -tt`es to the
  owning host and attaches there.

  Re-opening focuses the existing tab (matched by exact title) instead of
  spawning a duplicate — the same idempotent focus-then-launch Portolan's
  server uses. macOS in practice (kitty + `osascript` to raise the window);
  a host without kitty, or a kitty without remote control enabled, fails
  cleanly with `{:error, reason}` and the board surfaces a toast.

  Requires kitty's remote control to be reachable from outside a kitty window —
  i.e. `allow_remote_control yes` + a `listen_on unix:/tmp/kitty` in kitty.conf
  (or a `--listen-on` launch). The daemon isn't itself a kitty window, so it
  discovers the most-recently-touched `/tmp/kitty-*` socket (falling back to
  `$KITTY_LISTEN_ON` when the daemon *was* launched inside kitty).
  """

  require Logger

  @kitty_candidates [
    "/opt/homebrew/bin/kitty",
    "/usr/local/bin/kitty",
    "/Applications/kitty.app/Contents/MacOS/kitty"
  ]

  @doc """
  Open (or focus) `session` in a kitty tab. `host` is the fiber's
  `shuttle.host`: nil / "" / this daemon's own host id → a local
  `tmux attach`; any other value → a local tab that `ssh -tt`es to `host`.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec open(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def open(session, host \\ nil)

  def open(session, host) when is_binary(session) and session != "" do
    with {:ok, kitty} <- kitty_bin() do
      socket = kitty_socket()
      remote? = remote_host?(host)
      title = if remote?, do: "#{session}@#{host}", else: session

      result =
        case focus_tab(kitty, socket, title) do
          :ok -> :ok
          :miss -> launch_tab(kitty, socket, title, session, host, remote?)
        end

      case result do
        :ok ->
          activate(kitty)
          :ok

        {:error, _} = err ->
          err
      end
    end
  end

  def open(_session, _host), do: {:error, "tmux_session is required"}

  # ── kitty remote-control plumbing ──────────────────────────────────────────

  # Focus an existing tab whose title matches exactly. `:ok` when one was
  # focused; `:miss` when none matched (or remote control was unreachable —
  # the launch path then surfaces the real error).
  defp focus_tab(kitty, socket, title) do
    args = ["@"] ++ to_opt(socket) ++ ["focus-tab", "--match", "title:^#{title}$"]

    case run(kitty, args) do
      {_out, 0} -> :ok
      _ -> :miss
    end
  end

  # Launch a fresh tab running the attach command. Local: `tmux attach -t
  # =<session>`. Remote: `ssh -tt <host> tmux attach -t =<session>`, carrying
  # the daemon's SSH_AUTH_SOCK into the tab so agent auth works.
  defp launch_tab(kitty, socket, title, session, host, remote?) do
    attach = attach_command(session, host, remote?)

    env =
      if remote? do
        case System.get_env("SSH_AUTH_SOCK") do
          s when is_binary(s) and s != "" -> ["--env", "SSH_AUTH_SOCK=" <> s]
          _ -> []
        end
      else
        []
      end

    args =
      ["@"] ++
        to_opt(socket) ++ ["launch", "--type=tab"] ++ env ++ ["--title", title] ++ attach

    case run(kitty, args) do
      {_out, 0} ->
        :ok

      {out, code} ->
        {:error, "kitty launch exited #{code}: #{out |> String.trim() |> String.slice(0, 240)}"}
    end
  end

  @doc """
  The inner attach command kitty runs in the new tab. Local → `tmux attach -t
  =<session>` (the leading `=` forces an exact session match); remote → the same
  wrapped in `ssh -tt <host>`. Pure, so the local/remote shape is unit-testable
  without spawning kitty.
  """
  @spec attach_command(String.t(), String.t() | nil) :: [String.t()]
  def attach_command(session, host), do: attach_command(session, host, remote_host?(host))

  defp attach_command(session, host, remote?) do
    target = "=" <> session

    if remote? do
      ["ssh", "-tt", host, "tmux", "attach", "-t", target]
    else
      ["tmux", "attach", "-t", target]
    end
  end

  # Raise kitty to the front (best-effort, macOS).
  defp activate(_kitty) do
    run("osascript", ["-e", ~s(tell application "kitty" to activate)])
    :ok
  end

  defp to_opt(nil), do: []
  defp to_opt(socket), do: ["--to", socket]

  # The `--to` target: `$KITTY_LISTEN_ON` when the daemon itself runs inside a
  # kitty, else the most-recently-touched `/tmp/kitty-*` socket. nil → let
  # kitty try its own default (works when a single socket is unambiguous).
  defp kitty_socket do
    case System.get_env("KITTY_LISTEN_ON") do
      s when is_binary(s) and s != "" -> s
      _ -> latest_tmp_socket()
    end
  end

  defp latest_tmp_socket do
    "/tmp/kitty-*"
    |> Path.wildcard()
    |> Enum.flat_map(fn p ->
      case File.stat(p, time: :posix) do
        {:ok, %File.Stat{mtime: m}} -> [{p, m}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_p, m} -> m end, :desc)
    |> case do
      [{path, _} | _] -> "unix:" <> path
      [] -> nil
    end
  end

  defp kitty_bin do
    case System.find_executable("kitty") || Enum.find(@kitty_candidates, &File.exists?/1) do
      nil -> {:error, "kitty not found on this host (is it installed / on PATH?)"}
      path -> {:ok, path}
    end
  end

  # `shuttle.host` is local iff absent/empty or equal to this daemon's own id.
  defp remote_host?(host) do
    case host do
      h when is_binary(h) and h != "" -> h != Shuttle.Poller.own_host_id()
      _ -> false
    end
  end

  # System.cmd raises (ErlangError :enoent) when the executable is missing; we
  # pre-resolve kitty, but osascript / kitty edge cases shouldn't crash the
  # request — fold any spawn failure into a non-zero result.
  defp run(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  rescue
    e -> {Exception.message(e), 127}
  end
end
