# Shuttle daemon + CLI — build + lifecycle
#
# Two artifacts share this repo:
#   - bin/shuttle  (Elixir escript) — the daemon. Loads BEAMs at boot;
#     `make restart` rebuilds + bounces.
#   - shuttle-ctl  (Go binary)      — the agent-facing CLI. Built into
#     $(CLI_DEST) which sits on PATH; `make cli` rebuilds + installs.
#
# `make restart` is the load-bearing daemon target. `make cli` is the
# load-bearing CLI target — when a new shuttle-ctl verb lands, any
# tool that shells out to it will silently break with a stale binary.
# The daemon and CLI are independent (Elixir vs Go), so building one
# never implies rebuilding the other; `make all` does both.

LOG := $(HOME)/Library/Logs/shuttle.log
# Match both the local `bin/shuttle ... -extra bin/shuttle start` shape and
# remote respawn-loop `./bin/shuttle ... -extra ./bin/shuttle start` shape.
# `[b]in` prevents pgrep from matching its own shell command.
PIDPATTERN := [b]in/shuttle -B .* -extra \.?/?bin/shuttle start
CLI_DEST := $(HOME)/go/bin/shuttle-ctl
AGENT_LABEL := io.shuttle.daemon
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT_LABEL).plist
# Felt stores the launchd daemon polls. Defaults to the loom aggregate (~/loom,
# outside ~/Documents) so the agent touches no TCC-protected path and needs no
# Full Disk Access. Override to add stores: make install-agent AGENT_LOOM_HOMES=~/loom,/some/other
AGENT_LOOM_HOMES ?= $(HOME)/loom
# The daemon's PATH, captured from a login shell at install time so it carries
# Homebrew (escript/erl), ~/.local/bin (felt), ~/go/bin (shuttle-ctl), etc. —
# launchd's own env is too bare, and sourcing the profile at runtime under
# launchd doesn't reconstruct it. This is the user's real PATH, frozen.
AGENT_PATH ?= $(shell /bin/bash -lc 'echo $$PATH')
# The user's PERSISTENT ssh-agent socket. launchd hands the daemon a bare
# per-session Keychain agent that only holds the default key, so remote creds
# added to the real agent — e.g. cineca's step-ca SSH cert — are invisible and
# fresh ssh to cineca fails (dead remote feed; Attach tabs that open and die).
# ~/.ssh/agent.sock is the stable login-agent path; override if yours differs.
AGENT_SSH_AUTH_SOCK ?= $(HOME)/.ssh/agent.sock

.PHONY: all build cli start stop restart logs status clean help install-agent uninstall-agent

# share/agents.json is the single source of truth for the agent registry.
# The Elixir daemon reads it at compile/runtime. The Go CLI reads it at
# runtime via FindSharePath, falling back to an embedded copy when the
# share/ dir isn't adjacent to the binary. That embedded copy lives in
# pkg/schema/agents_embedded.go and is regenerated from share/agents.json
# by this rule — never hand-edit the .go file.
pkg/schema/agents_embedded.go: share/agents.json
	@printf '%s\n' 'package schema' '' \
	  '// embeddedAgentJSON is generated from share/agents.json by `make` —' \
	  '// do not hand-edit. Run `make pkg/schema/agents_embedded.go` (or any' \
	  '// target that depends on it, e.g. `make cli`) to regenerate.' \
	  'var embeddedAgentJSON = []byte(`' > $@
	@cat $< >> $@
	@printf '%s\n' '`)' >> $@
	@echo "regenerated $@ from $<"

help:
	@echo "shuttle daemon:"
	@echo "  make build    — rebuild bin/shuttle escript (MIX_ENV=dev)"
	@echo "  make start    — start daemon detached (logs → $(LOG))"
	@echo "  make stop     — SIGTERM the running daemon"
	@echo "  make restart  — build + stop + start"
	@echo "  make install-agent   — durable launchd keep-alive (crash + login restart)"
	@echo "  make uninstall-agent — remove the launchd agent"
	@echo "  make logs     — tail -f the daemon log"
	@echo "  make status   — shuttle-ctl ps + snapshot summary"
	@echo "  make clean    — remove _build and stray .beam files"
	@echo ""
	@echo "shuttle-ctl CLI (Go):"
	@echo "  make cli      — go build → $(CLI_DEST) (must be on PATH)"
	@echo ""
	@echo "everything:"
	@echo "  make all      — restart (daemon) + cli"

all: restart cli

build:
	mix shuttle.gen_version
	mix escript.build

# Build the Go CLI and install to $(CLI_DEST). `go install ./cmd/shuttle`
# would output as `shuttle` (matches cobra Use:), so we use `go build -o`
# to land it under the historical `shuttle-ctl` name.
cli: pkg/schema/agents_embedded.go
	@go build -o $(CLI_DEST) ./cmd/shuttle
	@echo "shuttle-ctl → $(CLI_DEST) ($$($(CLI_DEST) --help 2>/dev/null | head -1))"

start:
	@if pgrep -f '$(PIDPATTERN)' >/dev/null; then \
	  echo "shuttle already running (pid $$(pgrep -f '$(PIDPATTERN)'))"; exit 1; \
	fi
	@echo "=== shuttle start $$(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> $(LOG)
	@nohup bin/shuttle start >> $(LOG) 2>&1 &
	@sleep 1
	@if pgrep -f '$(PIDPATTERN)' >/dev/null; then \
	  echo "shuttle started (pid $$(pgrep -f '$(PIDPATTERN)')); logs → $(LOG)"; \
	else \
	  echo "shuttle failed to start; check $(LOG)"; exit 1; \
	fi

stop:
	@pid=$$(pgrep -f '$(PIDPATTERN)'); \
	if [ -n "$$pid" ]; then \
	  echo "stopping shuttle (pid $$pid)"; \
	  kill -TERM $$pid; \
	  for i in 1 2 3 4 5; do sleep 1; pgrep -f '$(PIDPATTERN)' >/dev/null || break; done; \
	  pgrep -f '$(PIDPATTERN)' >/dev/null && (echo "force-killing"; kill -9 $$pid) || echo "stopped"; \
	else \
	  echo "shuttle not running"; \
	fi

restart: build stop start

# ── Durable launch (macOS LaunchAgent) ──────────────────────────────────
# Shuttle's own keep-alive, independent of any other process. Installs a
# launchd agent that restarts the daemon on crash (KeepAlive) and starts it
# at login (RunAtLoad). This replaces leaning on an external supervisor for
# the local production surface. The escript is built first so the agent has a
# binary to run; `make stop` clears any nohup-spawned daemon so launchd owns
# the single live instance.
install-agent: build stop
	@case "$(CURDIR)" in \
	  $(HOME)/Documents/*|$(HOME)/Desktop/*|$(HOME)/Downloads/*) \
	    echo "⚠️  $(CURDIR) is under a TCC-protected folder (~/Documents, ~/Desktop,"; \
	    echo "    ~/Downloads). launchd-spawned processes are blocked from these, and"; \
	    echo "    Full Disk Access does NOT inherit across the launchd process tree —"; \
	    echo "    so the daemon will crash-loop or silently fail its felt-store walks."; \
	    echo "    Fix: run from a checkout OUTSIDE these folders (canonical: ~/dev/shuttle)."; \
	    echo "    Installing the agent anyway, but it will not work from here." ;; \
	esac
	@mkdir -p $(HOME)/Library/LaunchAgents
	@sed -e 's#__SHUTTLE_DIR__#$(CURDIR)#g' -e 's#__LOG__#$(LOG)#g' \
	  -e 's#__LOOM_HOMES__#$(AGENT_LOOM_HOMES)#g' -e 's#__PATH__#$(AGENT_PATH)#g' \
	  -e 's#__SSH_AUTH_SOCK__#$(AGENT_SSH_AUTH_SOCK)#g' \
	  share/io.shuttle.daemon.plist.template > $(AGENT_PLIST)
	@launchctl unload $(AGENT_PLIST) 2>/dev/null || true
	@launchctl load $(AGENT_PLIST)
	@echo "loaded $(AGENT_LABEL) → daemon will keep-alive + start at login"
	@echo "logs → $(LOG)   (launchctl list | grep shuttle  to inspect)"

uninstall-agent:
	@launchctl unload $(AGENT_PLIST) 2>/dev/null || true
	@rm -f $(AGENT_PLIST)
	@echo "unloaded + removed $(AGENT_LABEL)"

logs:
	@tail -f $(LOG)

status:
	@shuttle-ctl ps 2>/dev/null || echo "(shuttle-ctl ps unavailable)"
	@echo
	@bin/shuttle snapshot 2>/dev/null | python3 -c "import json,sys; o=json.load(sys.stdin); \
	  print('felt_hosts:', o.get('felt_hosts','MISSING (binary pre-297a24d)')); \
	  print('running:', [e.get('fiber_id') for e in o.get('eligible',[])]); \
	  print('claimed:', o.get('claimed_count'),'/',o.get('max_concurrent'))" \
	  2>/dev/null || echo "(daemon not responding)"

clean:
	rm -rf _build
	rm -f Elixir.*.beam
