import Config

config :shuttle, :agents, [
  # Claude (Anthropic) — default; runs against the weekly Claude subscription
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
  # Anthropic via pi (GitHub Copilot, max thinking allowed) — Copilot fill-in
  [
    id: "pi-sonnet",
    cli: "pi",
    wrapper: "pi",
    provider: "github-copilot",
    model: "claude-sonnet-4.6:high",
    requires_model: true
  ],

  # GPT 5.4 via pi (GitHub Copilot, max thinking)
  [
    id: "pi-gpt-5.4",
    cli: "pi",
    wrapper: "pi",
    provider: "github-copilot",
    model: "gpt-5.4:xhigh",
    requires_model: true
  ],

  # GPT 5.4 mini via pi (GitHub Copilot, 0.3× message multiplier — cheap)
  [
    id: "pi-gpt-5.4-mini",
    cli: "pi",
    wrapper: "pi",
    provider: "github-copilot",
    model: "gpt-5.4-mini:xhigh",
    requires_model: true
  ],

  # GPT-5 mini via pi (GitHub Copilot, 0× multiplier — free)
  [
    id: "pi-gpt-5-mini",
    cli: "pi",
    wrapper: "pi",
    provider: "github-copilot",
    model: "gpt-5-mini:xhigh",
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
