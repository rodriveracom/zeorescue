# zeo-rescue: the org's recovery path. Nothing here runs until someone asks. See RUNBOOK.md.
SHELL := /bin/bash
ARGS ?=
# ZEO_RESCUE_STATE, as rescue.sh reads it: without it, a test with a stub rescue.sh wrote its reseat log here for real.
STATE ?= $(or $(ZEO_RESCUE_STATE),$(HOME)/.local/state/zeo-rescue)
STAMP := $(shell date +%Y%m%d-%H%M%S)

.PHONY: help plan rescue reseat-plan reseat check agent test teardown-log

help:
	@echo "make plan                  what would be resumed; starts nothing"
	@echo "make rescue                resume every dead seat on this host, each from its own record"
	@echo "make reseat-plan           which live seats were started the wrong way; starts nothing"
	@echo "make reseat                restart those seats the right way, and stop the shared Codex daemon"
	@echo "make check                 judge every seat: its own identity, not on the daemon"
	@echo "make teardown-log          write the system log around a crash to a file this seat can read"
	@echo "make agent                 start the rescue seat detached, on its own tmux socket"
	@echo "make test                  the hermetic test"
	@echo "ARGS='...' limits any of them; see rescue.sh for the flags. Output of rescue and reseat is also kept in $(STATE)."

plan:
	@./rescue.sh $(ARGS)

rescue:
	@mkdir -p "$(STATE)"; set -o pipefail; ./rescue.sh --apply $(ARGS) 2>&1 | tee "$(STATE)/rescue-$(STAMP).log"

reseat-plan:
	@./rescue.sh --reseat $(ARGS)

reseat:
	@mkdir -p "$(STATE)"; set -o pipefail; ./rescue.sh --reseat --apply $(ARGS) 2>&1 | tee "$(STATE)/reseat-$(STAMP).log"

check:
	@./rescue.sh --check $(ARGS)

teardown-log:
	@./teardown-log.sh $(ARGS)

agent:
	@./agent.sh

test:
	@bash ./rescue-test.sh
	@bash ./tmux-test.sh
