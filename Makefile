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
PIDPATTERN := bin/shuttle.*-extra.*start
CLI_DEST := $(HOME)/go/bin/shuttle-ctl

.PHONY: all build cli start stop restart logs status clean help

help:
	@echo "shuttle daemon:"
	@echo "  make build    — rebuild bin/shuttle escript (MIX_ENV=dev)"
	@echo "  make start    — start daemon detached (logs → $(LOG))"
	@echo "  make stop     — SIGTERM the running daemon"
	@echo "  make restart  — build + stop + start"
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
	mix escript.build

# Build the Go CLI and install to $(CLI_DEST). `go install ./cmd/shuttle`
# would output as `shuttle` (matches cobra Use:), so we use `go build -o`
# to land it under the historical `shuttle-ctl` name.
cli:
	@go build -o $(CLI_DEST) ./cmd/shuttle
	@echo "shuttle-ctl → $(CLI_DEST) ($$($(CLI_DEST) --help 2>/dev/null | head -1))"

start:
	@if pgrep -f '$(PIDPATTERN)' >/dev/null; then \
	  echo "shuttle already running (pid $$(pgrep -f '$(PIDPATTERN)'))"; exit 1; \
	fi
	@nohup bin/shuttle start > $(LOG) 2>&1 &
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
