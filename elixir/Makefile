.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e udp-gh udp-gh-test install-udp-gh

MIX ?= mix
GO ?= go
PREFIX ?= /usr/local
UDP_GH_DIR := tools/udp-gh
UDP_GH_BINARY := bin/udp-gh
UDP_GH_VERSION ?= dev

help:
	@echo "Targets: setup, deps, build, udp-gh, install-udp-gh, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build: udp-gh
	$(MIX) build

udp-gh:
	cd $(UDP_GH_DIR) && CGO_ENABLED=0 $(GO) build -trimpath -ldflags "-s -w -X main.version=$(UDP_GH_VERSION)" -o ../../$(UDP_GH_BINARY) ./cmd/udp-gh

udp-gh-test:
	cd $(UDP_GH_DIR) && $(GO) test ./...
	cd $(UDP_GH_DIR) && $(GO) vet ./...

install-udp-gh: udp-gh
	install -Dm755 $(UDP_GH_BINARY) $(DESTDIR)$(PREFIX)/bin/udp-gh

fmt:
	cd $(UDP_GH_DIR) && gofmt -w .
	$(MIX) format

fmt-check:
	test -z "$$(cd $(UDP_GH_DIR) && gofmt -l .)"
	$(MIX) format --check-formatted

lint: udp-gh-test
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
