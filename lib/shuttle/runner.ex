defmodule Shuttle.Runner do
  @moduledoc """
  Behavior for shell command execution.

  Default implementation shells out via System.cmd.
  Tests inject a mock module to capture commands without running them.
  """

  @callback cmd(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}

  defmodule Default do
    @behaviour Shuttle.Runner

    def cmd(command, args, opts) do
      System.cmd(command, args, opts)
    rescue
      e in ErlangError ->
        case e.original do
          :enoent -> {"#{command}: command not found", 127}
          _ -> reraise e, __STACKTRACE__
        end
    end
  end
end
