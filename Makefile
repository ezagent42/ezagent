# ezagent — local-ubuntu-CI harness shortcuts.
#
# Reproduce the ubuntu-only CI flakes (timing races: PluginIsolationWorkspaceTest,
# AgentReadTest, DefaultSessionTemplateSeedTest, PresenceReadReceiptsE2ETest) on a
# linux container — macOS cannot, the race needs the ubuntu runner's core count +
# owner-teardown churn. See docs/guide/ci-docker-local.md.
#
# The host is behind a clash proxy; build reaches hex/apt/npm via host.docker.internal.
# Override the proxy:  make ci.docker.build DOCKER_BUILD_PROXY=http://host.docker.internal:7896

# Prefer the `docker compose` plugin; fall back to the standalone `docker-compose`
# (OrbStack ships the standalone binary, not the plugin subcommand).
DOCKER_COMPOSE := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose" || echo "docker-compose")
COMPOSE := $(DOCKER_COMPOSE) -f docker/docker-compose.ci.yml
# default proxy for the build (the host clash/mihomo mixed-port listens on :7896)
DOCKER_BUILD_PROXY ?= http://host.docker.internal:7896
export DOCKER_BUILD_PROXY

.PHONY: ci.docker ci.docker.build ci.gate ci.full ci.repro ci.repro.amplify ci.shell ci.down

## ci.docker — build the image then run the lightweight deterministic gate (mirror the ci.yml gate job).
ci.docker: ci.docker.build ci.gate

## ci.docker.build — build the local-ubuntu-CI image (base on lock change + thin source layer).
ci.docker.build:
	docker/build-ci-image.sh

## ci.gate — run the LIGHTWEIGHT deterministic gate (the ci.yml `gate` chain) inside the linux container.
ci.gate:
	$(COMPOSE) run --build --rm ci gate

## ci.full — run the FULL `mix ci.local` (the ci.yml `full-suite` chain) inside the linux container.
ci.full:
	$(COMPOSE) run --build --rm ci full-suite

## ci.repro — hunt the ubuntu-only flake (seed sweep, cpuset=0-3 ~ CI's ~4 vCPU).
ci.repro:
	$(COMPOSE) run --rm ci repro

## ci.repro.amplify — same hunt, MORE race pressure: 2 cores + oversubscribed cases.
ci.repro.amplify:
	CPUSET=0-1 SCHEDULERS=2 MAX_CASES=8 $(COMPOSE) run --rm ci repro

## ci.shell — drop into the container (debug).
ci.shell:
	$(COMPOSE) run --rm ci shell

## ci.down — stop + remove the postgres service and volumes.
ci.down:
	$(COMPOSE) down -v
