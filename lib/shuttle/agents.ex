defmodule Shuttle.Agents do
  @moduledoc """
  Agent configuration loading and tag resolution.

  Agents are loaded from `share/agents.json` at compile time. That JSON file
  is the single source of truth shared with the Go CLI.
  """

  @type agent_record :: %{
          id: String.t(),
          cli: String.t() | nil,
          wrapper: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          base_url: String.t() | nil,
          extra_flags: String.t() | nil,
          requires_model: boolean(),
          effort_levels: [String.t()],
          default_effort: String.t() | nil,
          chrome_capable: boolean(),
          cost_class: String.t() | nil,
          alias_of: String.t() | nil,
          axes: map() | nil,
          aliases: [String.t()],
          default: boolean()
        }

  @external_resource Path.expand("../../share/agents.json", __DIR__)
  @embedded_agents File.read!(@external_resource) |> Jason.decode!(keys: :atoms)

  @doc """
  Returns the list of configured agent records.
  """
  @spec list() :: [agent_record()]
  def list do
    normalize_agents(@embedded_agents)
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
    alias_of = optional_string(agent, :alias_of)
    # Alias records (alias_of set) carry no cli/wrapper/model — only the base id
    # and an axes overlay. Base agents require cli/wrapper.
    {cli, wrapper} =
      if alias_of do
        {optional_string(agent, :cli), optional_string(agent, :wrapper)}
      else
        {required_string(agent, :cli), required_string(agent, :wrapper)}
      end

    %{
      id: required_string(agent, :id),
      cli: cli,
      wrapper: wrapper,
      provider: optional_string(agent, :provider),
      model: optional_string(agent, :model),
      base_url: optional_string(agent, :base_url),
      extra_flags: optional_string(agent, :extra_flags),
      requires_model: Keyword.get(agent, :requires_model, false),
      effort_levels: normalized_aliases(Keyword.get(agent, :effort_levels, [])),
      default_effort: optional_string(agent, :default_effort),
      chrome_capable: Keyword.get(agent, :chrome_capable, false),
      cost_class: optional_string(agent, :cost_class),
      alias_of: alias_of,
      axes: normalize_axes(Keyword.get(agent, :axes)),
      aliases: normalized_aliases(Keyword.get(agent, :aliases, [])),
      default: Keyword.get(agent, :default, false)
    }
  end

  defp normalize_axes(nil), do: nil

  defp normalize_axes(axes) when is_map(axes) do
    %{
      effort: axes |> Map.get(:effort) |> normalize_optional_string(),
      chrome: Map.get(axes, :chrome, false)
    }
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(v) when is_binary(v), do: v

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
      # Match by id first, then by alias — mirrors the Go registry's Find so a
      # block the Go CLI accepts (e.g. agent: codex, an alias of codex-gpt-5.5)
      # also resolves on the Elixir dispatch path.
      case find_by_id(agents, name) || find_by_alias(agents, name) do
        nil -> {:error, "unknown agent: #{name}"}
        agent -> {:ok, agent}
      end
    end
  end

  @doc """
  Resolves an agent name plus the block-declared axes (effort, chrome) into the
  base agent record augmented with the effective, validated `:effort` and
  `:chrome` keys.

  An alias record (`alias_of` set) expands to its base agent with the alias's
  `axes` overlaid *beneath* the block axes (block wins). Effort falls back
  through: block → alias overlay → base `default_effort`. Validation rejects an
  effort token outside the base agent's `effort_levels` (or any effort on an
  agent with none) and chrome on a non-chrome-capable harness.

  `block_effort` may be `nil`/`""`; `block_chrome` is a boolean.
  """
  @spec resolve_with_axes(String.t() | nil, String.t() | nil, boolean()) ::
          {:ok, agent_record()} | {:error, String.t()}
  def resolve_with_axes(name, block_effort, block_chrome) do
    with {:ok, rec} <- resolve_by_name(name) do
      apply_axes(rec, block_effort, block_chrome)
    end
  end

  @doc """
  Overlays axes onto a (possibly alias) agent record. See `resolve_with_axes/3`.
  """
  @spec apply_axes(agent_record(), String.t() | nil, boolean()) ::
          {:ok, agent_record()} | {:error, String.t()}
  def apply_axes(rec, block_effort, block_chrome) do
    {base, overlay} =
      if rec[:alias_of] do
        case find_by_id(list(), rec.alias_of) do
          nil -> {nil, %{}}
          base -> {base, rec[:axes] || %{}}
        end
      else
        {rec, %{}}
      end

    cond do
      base == nil ->
        {:error, "agent #{rec.id} aliases unknown base #{rec[:alias_of]}"}

      true ->
        effort =
          first_present([block_effort, overlay[:effort], base[:default_effort]])

        chrome = !!block_chrome or !!overlay[:chrome]

        with :ok <- validate_axes(base, effort, chrome) do
          {:ok, Map.merge(base, %{effort: effort, chrome: chrome})}
        end
    end
  end

  defp first_present(values) do
    Enum.find(values, fn v -> is_binary(v) and v != "" end)
  end

  defp validate_axes(base, effort, chrome) do
    levels = base[:effort_levels] || []

    cond do
      is_binary(effort) and effort != "" and levels == [] ->
        {:error, "agent #{base.id} does not support an effort axis"}

      is_binary(effort) and effort != "" and effort not in levels ->
        {:error,
         "effort #{effort} not allowed for agent #{base.id} (allowed: #{Enum.join(levels, ", ")})"}

      chrome and not base[:chrome_capable] ->
        {:error, "chrome not supported by agent #{base.id} (claude harness only)"}

      true ->
        :ok
    end
  end

  @doc """
  Builds the shell command string for invoking an agent with the dispatch prompt.

  ## Options

    * `:session_id` — for Claude agents only: pre-specifies the session UUID via
      `--session-id <uuid>`. Ignored for other harnesses. Allows the Shuttle
      daemon to know the session UUID before the worker runs, so it can record it
      in felt history at dispatch (the durable resume handle; slice 6 dropped the
      doc-resident `shuttle.session` block) rather than via post-hoc capture.
  """
  @spec build_command(agent_record(), String.t(), keyword()) :: String.t()
  def build_command(agent, prompt, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    flags = render_flags(agent)

    # The wrapper is a shell function sourced via bash -l.
    # For claude: stdin via here-string; --session-id can be pre-specified.
    # For codex/pi: positional arg.
    case agent.cli do
      "claude" ->
        session_flag =
          if session_id, do: "--session-id #{shell_escape(session_id)} ", else: ""
        "#{agent.wrapper} #{session_flag}#{flags} <<< #{shell_escape(prompt)}"

      "codex" ->
        "#{agent.wrapper} #{flags} #{shell_escape(prompt)}"

      "pi" ->
        "#{agent.wrapper} #{flags} #{shell_escape(prompt)}"

      _ ->
        "#{agent.wrapper} #{flags} #{shell_escape(prompt)}"
    end
  end

  @doc """
  Builds the shell command string for resuming a previous worker session.

  Each harness has a distinct resume invocation:
  - claude: `claude --resume <uuid>` (pre-specified UUID, deterministic)
  - codex:  `codex resume <uuid>` (UUID captured post-hoc after initial dispatch)
  - pi:     `pi --session <uuid>` (partial UUID also accepted)

  When `prompt` is non-empty (whitespace-trimmed), it is injected as the
  next user turn in the resumed session — mirroring the fresh-dispatch
  pattern (claude reads it via `<<<` here-string; codex takes it as a
  positional arg). Without it, resume would land the worker in a session
  with no signal that it was deliberately woken — Cail's directive would
  sit silently in `felt history` instead of surfacing.

  Pi has no inline-prompt arg on `pi --session`, so the directive is
  dropped on resume for pi today; the worker can still query
  `felt history` to surface it.

  Extra flags (provider, model, extra_flags) are threaded through so the
  harness wrapper runs with the same configuration as the original session.
  """
  @spec build_resume_command(agent_record(), String.t(), String.t()) :: String.t()
  def build_resume_command(agent, session_id, prompt \\ "") do
    flags = render_flags(agent)

    has_prompt = is_binary(prompt) and String.trim(prompt) != ""

    case agent.cli do
      "claude" ->
        # Claude resumes from on-disk transcript. With a prompt, feed it
        # via stdin (here-string) so it lands as the next user turn —
        # mirrors fresh dispatch's `<<<` pattern.
        base = "#{agent.wrapper} #{flags} --resume #{shell_escape(session_id)}"
        if has_prompt, do: "#{base} <<< #{shell_escape(prompt)}", else: base

      "codex" ->
        # codex resume <uuid> [prompt] — resume subcommand, UUID positional,
        # optional prompt as trailing positional.
        base = "#{agent.wrapper} #{flags} resume #{shell_escape(session_id)}"
        if has_prompt, do: "#{base} #{shell_escape(prompt)}", else: base

      "pi" ->
        # pi --session <path|partial-uuid> — accepts UUID prefix. No inline
        # prompt arg today, so the directive is dropped on pi resume.
        "#{agent.wrapper} #{flags} --session #{shell_escape(session_id)}"

      _ ->
        # Unknown harness: fall back to fresh dispatch with a note.
        "#{agent.wrapper} #{flags} #{shell_escape("Resume session #{session_id} if possible.")}"
    end
  end

  # Renders the harness invocation flags, folding the resolved axes (effort,
  # chrome) into each CLI's native form:
  #   claude → `--effort <level>` flag + `--chrome`
  #   pi     → `:level` suffix on the model string (preserves today's behaviour)
  #   codex  → `-c model_reasoning_effort="<level>"`
  # Effort/chrome come from the agent map's `:effort`/`:chrome` keys set by
  # apply_axes/3; absent (raw record) means no axis rendering.
  defp render_flags(agent) do
    effort = agent[:effort]
    chrome = agent[:chrome] == true
    model = effective_model(agent, effort)

    [
      flag("--provider", agent.provider),
      flag("--model", model),
      effort_flag(agent.cli, effort),
      if(chrome, do: "--chrome", else: nil),
      agent.extra_flags
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # pi renders effort as a `:level` suffix on the model string; other harnesses
  # keep the bare model.
  defp effective_model(%{cli: "pi", model: model}, effort)
       when is_binary(model) and is_binary(effort) and effort != "" do
    "#{model}:#{effort}"
  end

  defp effective_model(agent, _effort), do: agent.model

  defp effort_flag("claude", effort) when is_binary(effort) and effort != "",
    do: "--effort #{shell_escape(effort)}"

  defp effort_flag("codex", effort) when is_binary(effort) and effort != "",
    do: "-c model_reasoning_effort=#{shell_escape(effort)}"

  defp effort_flag(_cli, _effort), do: nil

  defp flag(_key, nil), do: nil
  defp flag(key, value), do: "#{key} #{shell_escape(value)}"

  defp shell_escape(str) do
    # Single-quote escaping: replace ' with '\''
    escaped = String.replace(str, "'", "'\\''")
    "'#{escaped}'"
  end
end
