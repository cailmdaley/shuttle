# Shuttle daemon — build + lifecycle
#
# `make restart` is the load-bearing one: rebuilds the escript, kills the
# running daemon, and starts a detached daemon with stdout/stderr piped to
# ~/Library/Logs/shuttle.log. The escript loads its BEAMs at boot, so a
# rebuild without restart is a no-op for an already-running daemon — the two
# steps are bundled here for that reason.

LOG := $(HOME)/Library/Logs/shuttle.log
PIDPATTERN := bin/shuttle.*-extra.*start

.PHONY: build start stop restart logs status clean help

help:
	@echo "shuttle daemon:"
	@echo "  make build    — rebuild bin/shuttle escript (MIX_ENV=dev)"
	@echo "  make start    — start daemon detached (logs → $(LOG))"
	@echo "  make stop     — SIGTERM the running daemon"
	@echo "  make restart  — build + stop + start"
	@echo "  make logs     — tail -f the daemon log"
	@echo "  make status   — shuttle-ctl ps + snapshot summary"
	@echo "  make clean    — remove _build and stray .beam files"

build:
	mix escript.build

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
