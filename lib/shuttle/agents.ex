defmodule Shuttle.Agents do
  @moduledoc """
  Agent configuration loading and tag resolution.

  For Stage 2, agents are hardcoded inline. Stage 3+ will load from
  config/agents.exs.
  """

  @type agent_record :: %{
          id: String.t(),
          cli: String.t(),
          wrapper: String.t(),
          provider: String.t() | nil,
          model: String.t() | nil,
          base_url: String.t() | nil,
          extra_flags: String.t() | nil,
          requires_model: boolean(),
          aliases: [String.t()],
          default: boolean()
        }

  @default_agents [
    %{
      id: "claude",
      cli: "claude",
      wrapper: "claude",
      provider: nil,
      model: nil,
      base_url: nil,
      extra_flags: "--dangerously-skip-permissions",
      requires_model: false,
      aliases: [],
      default: true
    },
    %{
      id: "codex",
      cli: "codex",
      wrapper: "codex",
      provider: nil,
      model: nil,
      base_url: nil,
      extra_flags: "--dangerously-bypass-approvals-and-sandbox",
      requires_model: false,
      aliases: ["codex"],
      default: false
    },
    %{
      id: "pi-google",
      cli: "pi",
      wrapper: "pi",
      provider: "google",
      model: "google/gemini-2.5-pro-preview",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: ["pi"],
      default: false
    },
    %{
      id: "pi-anthropic",
      cli: "pi",
      wrapper: "pi",
      provider: "anthropic",
      model: "claude-sonnet-4-20250514",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: [],
      default: false
    },
    %{
      id: "pi-openai",
      cli: "pi",
      wrapper: "pi",
      provider: "openrouter",
      model: "openai/gpt-4o-mini",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: [],
      default: false
    }
  ]

  @doc """
  Returns the list of configured agent records.
  """
  @spec list() :: [agent_record()]
  def list, do: @default_agents

  @doc """
  Resolves an agent record from a fiber's tags.

  Resolution order:
  1. First `agent:<name>` compound tag
  2. Bare `codex` tag (alias)
  3. Bare `pi` tag (alias)
  4. Default agent
  """
  @spec resolve([String.t()]) :: {:ok, agent_record()} | {:error, String.t()}
  def resolve(tags) when is_list(tags) do
    agents = list()

    # 1. agent:<name> compound tag
    compound =
      Enum.find_value(tags, fn tag ->
        case String.split(tag, ":", parts: 2) do
          ["agent", name] -> find_by_id(agents, name)
          _ -> nil
        end
      end)

    # 2. Bare codex tag
    bare_codex = if "codex" in tags, do: find_by_alias(agents, "codex"), else: nil

    # 3. Bare pi tag
    bare_pi = if "pi" in tags, do: find_by_alias(agents, "pi"), else: nil

    # 4. Default
    default = Enum.find(agents, & &1.default)

    case compound || bare_codex || bare_pi || default do
      nil -> {:error, "no agent configured"}
      agent -> {:ok, agent}
    end
  end

  defp find_by_id(agents, id) do
    id = String.downcase(id)
    Enum.find(agents, fn a -> String.downcase(a.id) == id end)
  end

  defp find_by_alias(agents, alias_name) do
    alias_name = String.downcase(alias_name)

    Enum.find(agents, fn a ->
      Enum.any?(a.aliases, &(&1 == alias_name))
    end)
  end

  @doc """
  Builds the shell command string for invoking an agent with the dispatch prompt.
  """
  @spec build_command(agent_record(), String.t()) :: String.t()
  def build_command(agent, prompt) do
    flags =
      [
        flag("--provider", agent.provider),
        flag("--model", agent.model),
        agent.extra_flags
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    # The wrapper is a shell function sourced via bash -l.
    # For claude: stdin via here-string
    # For codex/pi: positional arg
    case agent.cli do
      "claude" ->
        "#{agent.wrapper} #{flags} <<< #{shell_escape(prompt)}"

      "codex" ->
        "#{agent.wrapper} #{flags} #{shell_escape(prompt)}"

      "pi" ->
        "#{agent.wrapper} #{flags} #{shell_escape(prompt)}"

      _ ->
        "#{agent.wrapper} #{flags} #{shell_escape(prompt)}"
    end
  end

  defp flag(_key, nil), do: nil
  defp flag(key, value), do: "#{key} #{shell_escape(value)}"

  defp shell_escape(str) do
    # Single-quote escaping: replace ' with '\''
    escaped = String.replace(str, "'", "'\\''")
    "'#{escaped}'"
  end
end
