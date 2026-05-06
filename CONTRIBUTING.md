# Contributing to Shuttle

Thank you for your interest in Shuttle.

## Getting started

```bash
git clone https://github.com/cailmdaley/shuttle
cd shuttle
mix deps.get && mix compile
make cli
```

Requirements: Erlang/OTP 26+, Elixir 1.16+, Go 1.21+, the `felt` CLI.

## Running tests

```bash
mix test                   # Elixir suite
go test ./pkg/schema/...   # Go schema tests
```

CI runs `mix compile --warnings-as-errors`, `mix test`, and
`go test ./pkg/schema/...` on every PR.

## Invariants

Before opening a PR, verify:

- `mix compile --warnings-as-errors` passes
- `mix test` passes
- `go test ./pkg/schema/...` passes
- No personal paths (`~/loom`, `/Users/...`) in tracked files
- `share/agents.json` is the only agent registry — do not add a parallel
  registry in Elixir config or Go source

## Scope

Shuttle is deliberately personal-scale: no auth model, no team conventions,
felt as the only work source. Contributions that add general-purpose
infrastructure are welcome; contributions that add a specific integration
layer belong in a fork or a `Shuttle.WorkSource` adapter once that
abstraction lands.

## Opening issues

- **Bugs:** include steps to reproduce and the output of `bin/shuttle snapshot`.
- **Features:** describe the problem, not just the solution. A concrete
  use-case helps.

## License

By contributing, you agree that your contributions will be licensed under
the Apache License 2.0.
