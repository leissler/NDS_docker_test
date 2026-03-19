SHELL := /bin/sh

PROJECT_DIR := $(abspath $(CURDIR))
BUILD_SCRIPT ?= build.py
DOCKERFILE ?= Dockerfile
BUILDER_IMAGE ?= ndscompiler-builder
DEVCONTAINER_IMAGE ?= nds-devcontainer

.PHONY: help build build-debug build-latest build-latest-debug build-local run run-debug run-no-build run-debug-no-build clean-run clean-run-debug clean distclean _build _run

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
	@echo "  make distclean     - clean + remove local Docker build images (host only)"

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
	elif command -v docker >/dev/null 2>&1; then \
		if [ "$(LATEST)" = "1" ]; then \
			docker build --pull --no-cache -f $(DOCKERFILE) --target builder -t $(BUILDER_IMAGE) .; \
		else \
			docker build -f $(DOCKERFILE) --target builder -t $(BUILDER_IMAGE) .; \
		fi; \
		docker run --rm -e NDS_BUILD_PROFILE=$(PROFILE) -v "$(PROJECT_DIR):/test" -w /test $(BUILDER_IMAGE) python3 $(BUILD_SCRIPT); \
	else \
		echo "Error: no build environment found."; \
		echo "Use devcontainer, install local BlocksDS toolchain, or install Docker."; \
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
	find build output architectds/__pycache__ -type f -delete 2>/dev/null || true; \
	find build output architectds/__pycache__ -depth -type d -empty -delete 2>/dev/null || true; \
	echo "Clean complete."

distclean: clean
	@if [ ! -f /.dockerenv ] && [ -z "$$REMOTE_CONTAINERS" ] && command -v docker >/dev/null 2>&1; then \
		docker rmi -f ndscompiler ndscompiler-builder $(DEVCONTAINER_IMAGE) nds-devcontainer-test 2>/dev/null || true; \
		echo "Docker image cleanup complete."; \
	fi
