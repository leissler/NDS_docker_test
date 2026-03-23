SHELL := /bin/sh

PROJECT_DIR := $(abspath $(CURDIR))
BUILD_SCRIPT ?= build.py
DOCKERFILE ?= Dockerfile
BUILDER_IMAGE ?= ndscompiler-builder
DEVCONTAINER_IMAGE ?= nds-devcontainer

STAMP_DIR := .docker-stamps
BUILDER_STAMP := $(STAMP_DIR)/builder.stamp

CONTAINER_RUNTIME ?= $(shell \
	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then echo docker; \
	elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then echo podman; \
	elif command -v docker >/dev/null 2>&1; then echo docker; \
	elif command -v podman >/dev/null 2>&1; then echo podman; \
	fi)
DOCKER_START_TIMEOUT ?= 60

.PHONY: help build build-debug build-latest build-latest-debug build-local \
	run run-debug run-no-build run-debug-no-build clean-run clean-run-debug \
	clean distclean check-container-runtime docker-build-builder docker-build-builder-latest \
	ensure-builder-image clean-docker-stamps _build _run

help:
	@echo "Available targets:"
	@echo "  make build         - Build release ROM (devcontainer/local toolchain or Docker fallback)"
	@echo "  make build-debug   - Build debug ROM"
	@echo "  make build-latest  - Rebuild Docker toolchain with latest packages, then build release ROM"
	@echo "  make build-latest-debug - Rebuild Docker toolchain with latest packages, then build debug ROM"
	@echo "  make build-local   - Build directly with local toolchain (expects BLOCKSDS setup)"
	@echo "  make run           - Build release ROM, then run in emulator"
	@echo "  make run-debug     - Build debug ROM, then run in emulator"
	@echo "  make run-no-build  - Run release ROM in emulator without rebuilding"
	@echo "  make run-debug-no-build - Run debug ROM in emulator without rebuilding"
	@echo "  make clean-run     - Clean, rebuild release ROM, then run in emulator"
	@echo "  make clean-run-debug - Clean, rebuild debug ROM, then run in emulator"
	@echo "  make clean         - Remove generated build artifacts and ROMs"
	@echo "  make distclean     - clean + remove local Docker build images and stamps"
	@echo "  make docker-build-builder - Build/rebuild Docker builder image"
	@echo "  make check-container-runtime - Verify runtime and auto-start Docker Desktop when possible"

$(STAMP_DIR):
	@mkdir -p $(STAMP_DIR)

check-container-runtime:
	@set -e; \
	if [ -z "$(CONTAINER_RUNTIME)" ]; then \
		echo "No supported container runtime found. Install docker or podman."; \
		exit 1; \
	fi; \
	if ! command -v "$(CONTAINER_RUNTIME)" >/dev/null 2>&1; then \
		echo "Container runtime '$(CONTAINER_RUNTIME)' is not installed."; \
		exit 1; \
	fi; \
	if "$(CONTAINER_RUNTIME)" info >/dev/null 2>&1; then \
		exit 0; \
	fi; \
	if [ "$(CONTAINER_RUNTIME)" = "docker" ] && command -v open >/dev/null 2>&1 && [ -d "/Applications/Docker.app" ]; then \
		echo "Docker daemon is not running. Starting Docker Desktop..."; \
		open -a Docker; \
		i=0; \
		until "$(CONTAINER_RUNTIME)" info >/dev/null 2>&1; do \
			i=$$((i + 1)); \
			if [ $$i -ge "$(DOCKER_START_TIMEOUT)" ]; then \
				echo "Timed out waiting for Docker Desktop after $(DOCKER_START_TIMEOUT)s."; \
				exit 1; \
			fi; \
			sleep 1; \
		done; \
		echo "Docker Desktop is ready."; \
	elif [ "$(CONTAINER_RUNTIME)" = "docker" ] && grep -qi microsoft /proc/version 2>/dev/null; then \
		echo "Docker daemon is not running. Starting Docker Desktop from WSL..."; \
		if command -v powershell.exe >/dev/null 2>&1; then \
			powershell.exe -NoProfile -NonInteractive -Command "Start-Process 'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe'" >/dev/null 2>&1 || true; \
		elif command -v cmd.exe >/dev/null 2>&1; then \
			cmd.exe /C start "" "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe" >/dev/null 2>&1 || true; \
		fi; \
		i=0; \
		until "$(CONTAINER_RUNTIME)" info >/dev/null 2>&1; do \
			i=$$((i + 1)); \
			if [ $$i -ge "$(DOCKER_START_TIMEOUT)" ]; then \
				echo "Timed out waiting for Docker Desktop after $(DOCKER_START_TIMEOUT)s."; \
				exit 1; \
			fi; \
			sleep 1; \
		done; \
		echo "Docker Desktop is ready."; \
	else \
		echo "Container runtime '$(CONTAINER_RUNTIME)' is installed but not running."; \
		echo "Start the runtime or override with CONTAINER_RUNTIME=podman."; \
		exit 1; \
	fi

$(BUILDER_STAMP): $(DOCKERFILE) | $(STAMP_DIR)
	@$(MAKE) check-container-runtime
	@if $(CONTAINER_RUNTIME) image inspect $(BUILDER_IMAGE) >/dev/null 2>&1; then \
		echo "Rebuilding $(BUILDER_IMAGE) because Dockerfile changed..."; \
	else \
		echo "Docker image $(BUILDER_IMAGE) not found, building it..."; \
	fi
	$(CONTAINER_RUNTIME) build -f $(DOCKERFILE) --target builder -t $(BUILDER_IMAGE) .
	@touch $(BUILDER_STAMP)

docker-build-builder: ensure-builder-image

docker-build-builder-latest: check-container-runtime | $(STAMP_DIR)
	$(CONTAINER_RUNTIME) build --pull --no-cache -f $(DOCKERFILE) --target builder -t $(BUILDER_IMAGE) .
	@touch $(BUILDER_STAMP)

ensure-builder-image: check-container-runtime $(BUILDER_STAMP)

build:
	@$(MAKE) _build PROFILE=release LATEST=0

build-debug:
	@$(MAKE) _build PROFILE=debug LATEST=0

build-latest:
	@$(MAKE) _build PROFILE=release LATEST=1

build-latest-debug:
	@$(MAKE) _build PROFILE=debug LATEST=1

_build:
	@set -e; \
	if [ -f /.dockerenv ] || [ -n "$$REMOTE_CONTAINERS" ]; then \
		NDS_BUILD_PROFILE=$(PROFILE) python3 $(BUILD_SCRIPT); \
	elif command -v python3 >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1 && [ -n "$$BLOCKSDS" ] && [ -d "$$BLOCKSDS" ]; then \
		NDS_BUILD_PROFILE=$(PROFILE) python3 $(BUILD_SCRIPT); \
	elif [ -n "$(CONTAINER_RUNTIME)" ]; then \
		if [ "$(LATEST)" = "1" ]; then \
			$(MAKE) docker-build-builder-latest; \
		else \
			$(MAKE) ensure-builder-image; \
		fi; \
		$(CONTAINER_RUNTIME) run --rm -e NDS_BUILD_PROFILE=$(PROFILE) -v "$(PROJECT_DIR):/test" -w /test $(BUILDER_IMAGE) python3 $(BUILD_SCRIPT); \
	else \
		echo "Error: no build environment found."; \
		echo "Use devcontainer, install local BlocksDS toolchain, or install Docker/Podman."; \
		exit 1; \
	fi

build-local:
	@python3 $(BUILD_SCRIPT)

run: build
	@$(MAKE) _run MODE=release SKIP_BUILD=1

run-debug: build-debug
	@$(MAKE) _run MODE=debug SKIP_BUILD=1

run-no-build:
	@$(MAKE) _run MODE=release SKIP_BUILD=1

run-debug-no-build:
	@$(MAKE) _run MODE=debug SKIP_BUILD=1

_run:
	@set -e; \
	if command -v node >/dev/null 2>&1; then \
		NODE_BIN=node; \
	elif command -v nodejs >/dev/null 2>&1; then \
		NODE_BIN=nodejs; \
	else \
		echo "Error: node (or nodejs) not found."; \
		exit 1; \
	fi; \
	NDS_LAUNCH_MODE=$(MODE) NDS_LAUNCH_CONTEXT=auto NDS_SKIP_BUILD=$(SKIP_BUILD) "$$NODE_BIN" tools/run-emulator.mjs

clean-run:
	@$(MAKE) clean
	@$(MAKE) run

clean-run-debug:
	@$(MAKE) clean
	@$(MAKE) run-debug

clean:
	@set -e; \
	if [ -f /.dockerenv ] || [ -n "$$REMOTE_CONTAINERS" ] || (command -v python3 >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1 && [ -n "$$BLOCKSDS" ] && [ -d "$$BLOCKSDS" ]); then \
		python3 $(BUILD_SCRIPT) --clean || true; \
	fi; \
	find . -maxdepth 1 -name '*.nds' -delete; \
	find . -maxdepth 1 -name 'build.ninja' -delete; \
	find . -maxdepth 1 -name '.ninja_deps' -delete; \
	find . -maxdepth 1 -name '.ninja_log' -delete; \
	find build output architectds/__pycache__ scripts/__pycache__ tools/__pycache__ -type f -delete 2>/dev/null || true; \
	find build output architectds/__pycache__ scripts/__pycache__ tools/__pycache__ -depth -type d -empty -delete 2>/dev/null || true; \
	echo "Clean complete."

clean-docker-stamps:
	@rm -rf $(STAMP_DIR)

distclean: clean clean-docker-stamps
	@if [ ! -f /.dockerenv ] && [ -z "$$REMOTE_CONTAINERS" ] && [ -n "$(CONTAINER_RUNTIME)" ] && command -v "$(CONTAINER_RUNTIME)" >/dev/null 2>&1; then \
		$(CONTAINER_RUNTIME) rmi -f ndscompiler ndscompiler-builder $(DEVCONTAINER_IMAGE) nds-devcontainer-test 2>/dev/null || true; \
		echo "Docker image cleanup complete."; \
	fi
