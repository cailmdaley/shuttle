import Config

config :shuttle, :agents, [
  [
    id: "claude",
    cli: "claude",
    wrapper: "claude",
    extra_flags: "--dangerously-skip-permissions",
    default: true
  ],
  [
    id: "codex",
    cli: "codex",
    wrapper: "codex",
    extra_flags: "--dangerously-bypass-approvals-and-sandbox",
    aliases: ["codex"]
  ],
  [
    id: "pi-google",
    cli: "pi",
    wrapper: "pi",
    provider: "google",
    model: "google/gemini-2.5-pro-preview",
    requires_model: true,
    aliases: ["pi"]
  ],
  [
    id: "pi-anthropic",
    cli: "pi",
    wrapper: "pi",
    provider: "anthropic",
    model: "claude-sonnet-4-20250514",
    requires_model: true
  ],
  [
    id: "pi-openai",
    cli: "pi",
    wrapper: "pi",
    provider: "openrouter",
    model: "openai/gpt-4o-mini",
    requires_model: true
  ]
]
