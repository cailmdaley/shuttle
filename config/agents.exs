import Config

config :shuttle, :agents, [
  # Claude (Anthropic) — default, alias: claude
  [
    id: "claude-sonnet",
    cli: "claude",
    wrapper: "claude",
    model: "sonnet",
    extra_flags: "--dangerously-skip-permissions",
    default: true
  ],
  [
    id: "claude-opus",
    cli: "claude",
    wrapper: "claude",
    model: "opus",
    extra_flags: "--dangerously-skip-permissions"
  ],
  [
    id: "claude-haiku",
    cli: "claude",
    wrapper: "claude",
    model: "haiku",
    extra_flags: "--dangerously-skip-permissions"
  ],

  # Codex (OpenAI) — alias: codex
  [
    id: "codex",
    cli: "codex",
    wrapper: "codex",
    model: "gpt-5.5",
    extra_flags: "--dangerously-bypass-approvals-and-sandbox",
    aliases: ["codex"],
    default: false
  ],
  [
    id: "codex-mini",
    cli: "codex",
    wrapper: "codex",
    model: "gpt-5.4-mini",
    extra_flags: "--dangerously-bypass-approvals-and-sandbox"
  ],

  # Anthropic via pi (OpenRouter)
  [
    id: "pi-sonnet",
    cli: "pi",
    wrapper: "pi",
    provider: "openrouter",
    model: "anthropic/claude-sonnet-4",
    requires_model: true
  ],

  # OpenAI via pi (OpenRouter)
  [
    id: "pi-gpt",
    cli: "pi",
    wrapper: "pi",
    provider: "openrouter",
    model: "openai/gpt-4o",
    requires_model: true
  ],

  # Kimi via pi (OpenRouter)
  [
    id: "pi-kimi",
    cli: "pi",
    wrapper: "pi",
    provider: "openrouter",
    model: "moonshotai/kimi-k2.6",
    requires_model: true
  ],

  # DeepSeek via pi (OpenRouter) — alias: pi
  [
    id: "pi-deepseek-pro",
    cli: "pi",
    wrapper: "pi",
    provider: "openrouter",
    model: "deepseek/deepseek-v4-pro",
    requires_model: true
  ],
  [
    id: "pi-deepseek-flash",
    cli: "pi",
    wrapper: "pi",
    provider: "openrouter",
    model: "deepseek/deepseek-v4-flash",
    requires_model: true,
    aliases: ["pi"]
  ]
]
