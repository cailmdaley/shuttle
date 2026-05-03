defmodule Shuttle.Agents do
  @moduledoc """
  Agent configuration loading and tag resolution.

  Agents are configured through `config :shuttle, :agents`. The built-in
  records are the fallback so tests and local escripts still have a complete
  default surface when no config file has been loaded.
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
      id: "claude-sonnet",
      cli: "claude",
      wrapper: "claude",
      provider: nil,
      model: "sonnet",
      base_url: nil,
      extra_flags: "--dangerously-skip-permissions",
      requires_model: false,
      aliases: [],
      default: true
    },
    %{
      id: "claude-opus",
      cli: "claude",
      wrapper: "claude",
      provider: nil,
      model: "opus",
      base_url: nil,
      extra_flags: "--dangerously-skip-permissions",
      requires_model: false,
      aliases: [],
      default: false
    },
    %{
      id: "claude-haiku",
      cli: "claude",
      wrapper: "claude",
      provider: nil,
      model: "haiku",
      base_url: nil,
      extra_flags: "--dangerously-skip-permissions",
      requires_model: false,
      aliases: [],
      default: false
    },
    %{
      id: "codex",
      cli: "codex",
      wrapper: "codex",
      provider: nil,
      model: "gpt-5.5",
      base_url: nil,
      extra_flags: "--dangerously-bypass-approvals-and-sandbox",
      requires_model: false,
      aliases: ["codex"],
      default: false
    },
    %{
      id: "codex-mini",
      cli: "codex",
      wrapper: "codex",
      provider: nil,
      model: "gpt-5.4-mini",
      base_url: nil,
      extra_flags: "--dangerously-bypass-approvals-and-sandbox",
      requires_model: false,
      aliases: [],
      default: false
    },
    %{
      id: "pi-sonnet",
      cli: "pi",
      wrapper: "pi",
      provider: "openrouter",
      model: "anthropic/claude-sonnet-4",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: [],
      default: false
    },
    %{
      id: "pi-gpt",
      cli: "pi",
      wrapper: "pi",
      provider: "openrouter",
      model: "openai/gpt-4o",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: [],
      default: false
    },
    %{
      id: "pi-kimi",
      cli: "pi",
      wrapper: "pi",
      provider: "openrouter",
      model: "moonshotai/kimi-k2.6",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: ["pi"],
      default: false
    },
    %{
      id: "pi-deepseek-pro",
      cli: "pi",
      wrapper: "pi",
      provider: "openrouter",
      model: "deepseek/deepseek-v4-pro",
      base_url: nil,
      extra_flags: nil,
      requires_model: true,
      aliases: [],
      default: false
    },
    %{
      id: "pi-deepseek-flash",
      cli: "pi",
      wrapper: "pi",
      provider: "openrouter",
      model: "deepseek/deepseek-v4-flash",
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
  def list do
    :shuttle
    |> Application.get_env(:agents, @default_agents)
    |> normalize_agents()
  end

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
    default = Enum.find(agents, & &1.default) || List.first(agents)

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

  defp normalize_agents(agents) when is_list(agents) do
    Enum.map(agents, &normalize_agent/1)
  end

  defp normalize_agent(agent) when is_map(agent) do
    normalize_agent(Map.to_list(agent))
  end

  defp normalize_agent(agent) when is_list(agent) do
    %{
      id: required_string(agent, :id),
      cli: required_string(agent, :cli),
      wrapper: required_string(agent, :wrapper),
      provider: optional_string(agent, :provider),
      model: optional_string(agent, :model),
      base_url: optional_string(agent, :base_url),
      extra_flags: optional_string(agent, :extra_flags),
      requires_model: Keyword.get(agent, :requires_model, false),
      aliases: normalized_aliases(Keyword.get(agent, :aliases, [])),
      default: Keyword.get(agent, :default, false)
    }
  end

  defp required_string(agent, key) do
    case Keyword.fetch(agent, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "agent #{inspect(key)} must be a non-empty string, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "agent missing required #{inspect(key)}"
    end
  end

  defp optional_string(agent, key) do
    case Keyword.get(agent, key) do
      nil ->
        nil

      value when is_binary(value) ->
        value

      value ->
        raise ArgumentError,
              "agent #{inspect(key)} must be a string or nil, got: #{inspect(value)}"
    end
  end

  defp normalized_aliases(aliases) when is_list(aliases) do
    Enum.map(aliases, fn
      alias_name when is_binary(alias_name) ->
        String.downcase(alias_name)

      alias_name ->
        raise ArgumentError, "agent alias must be a string, got: #{inspect(alias_name)}"
    end)
  end

  @doc """
  Resolves an agent record from a shuttle.agent name string.

  Called by the dispatch path after migration, where agent identity lives in the
  shuttle: block rather than in agent:* tags. Falls back to the default agent
  when name is nil or empty.
  """
  @spec resolve_by_name(String.t() | nil) :: {:ok, agent_record()} | {:error, String.t()}
  def resolve_by_name(nil), do: resolve_by_name("")

  def resolve_by_name(name) when is_binary(name) do
    agents = list()

    if name == "" do
      case Enum.find(agents, & &1.default) || List.first(agents) do
        nil -> {:error, "no agent configured"}
        agent -> {:ok, agent}
      end
    else
      case find_by_id(agents, name) do
        nil -> {:error, "unknown agent: #{name}"}
        agent -> {:ok, agent}
      end
    end
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
