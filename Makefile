SHELL := /bin/sh

PROJECT_DIR := $(abspath $(CURDIR))
BUILD_SCRIPT ?= build.py
DOCKERFILE ?= Dockerfile
BUILDER_IMAGE ?= ndscompiler-builder
DEVCONTAINER_IMAGE ?= nds-devcontainer

.PHONY: help build build-latest build-local clean distclean

help:
	@echo "Available targets:"
	@echo "  make build         - Build ROM (devcontainer/local toolchain or Docker fallback)"
	@echo "  make build-latest  - Rebuild Docker toolchain with latest packages, then build"
	@echo "  make build-local   - Build directly with local toolchain (expects BLOCKSDS setup)"
	@echo "  make clean         - Remove generated build artifacts and ROMs"
	@echo "  make distclean     - clean + remove local Docker build images (host only)"

build:
	@set -e; \
	if [ -f /.dockerenv ] || [ -n "$$REMOTE_CONTAINERS" ]; then \
		python3 $(BUILD_SCRIPT); \
	elif command -v python3 >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1 && [ -n "$$BLOCKSDS" ] && [ -d "$$BLOCKSDS" ]; then \
		python3 $(BUILD_SCRIPT); \
	elif command -v docker >/dev/null 2>&1; then \
		docker build -f $(DOCKERFILE) --target builder -t $(BUILDER_IMAGE) .; \
		docker run --rm -v "$(PROJECT_DIR):/test" -w /test $(BUILDER_IMAGE) python3 $(BUILD_SCRIPT); \
	else \
		echo "Error: no build environment found."; \
		echo "Use devcontainer, install local BlocksDS toolchain, or install Docker."; \
		exit 1; \
	fi

build-latest:
	@set -e; \
	if [ -f /.dockerenv ] || [ -n "$$REMOTE_CONTAINERS" ]; then \
		echo "Inside devcontainer: rebuild the devcontainer image to refresh toolchain."; \
		python3 $(BUILD_SCRIPT); \
	elif command -v python3 >/dev/null 2>&1 && command -v ninja >/dev/null 2>&1 && [ -n "$$BLOCKSDS" ] && [ -d "$$BLOCKSDS" ]; then \
		echo "Using local toolchain from BLOCKSDS=$$BLOCKSDS"; \
		python3 $(BUILD_SCRIPT); \
	elif command -v docker >/dev/null 2>&1; then \
		docker build --pull --no-cache -f $(DOCKERFILE) --target builder -t $(BUILDER_IMAGE) .; \
		docker run --rm -v "$(PROJECT_DIR):/test" -w /test $(BUILDER_IMAGE) python3 $(BUILD_SCRIPT); \
	else \
		echo "Error: Docker not found and no local toolchain available."; \
		exit 1; \
	fi

build-local:
	@python3 $(BUILD_SCRIPT)

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
