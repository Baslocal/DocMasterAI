# DocMaster — Build Pipeline
# Usage: make build VERSION=1.0.0 METHOD=iso|lxc|installer|docker|all
#
# All targets run from the repo root. The build server must be isolated from
# the internet during production builds (air-gapped vendor mirror required).

VERSION    ?= 1.0.0
METHOD     ?= installer
BUILD_DIR  := build
DIST_DIR   := dist
PACKER_BIN := packer

DM_CORE_PORT := 8443
DM_USER      := dmuser
DM_GROUP     := docgroup
INSTALL_PATH := /opt/docmaster

.PHONY: all build iso lxc installer docker schema lint test clean help \
        build-ui check-packer check-version

# ─────────────────────────────────────────────────────────────────────────────
# Default target
# ─────────────────────────────────────────────────────────────────────────────
all: help

# ─────────────────────────────────────────────────────────────────────────────
# Primary build entry point
# ─────────────────────────────────────────────────────────────────────────────
build: check-version build-ui
	@echo ">>> DocMaster v$(VERSION) build — Method: $(METHOD)"
	@mkdir -p $(DIST_DIR)
	@$(MAKE) $(METHOD)

# ─────────────────────────────────────────────────────────────────────────────
# UI build (always runs first — output goes to www/dist/)
# ─────────────────────────────────────────────────────────────────────────────
build-ui:
	@echo ">>> Building React UI..."
	@cd www && npm ci --prefer-offline && npm run build
	@echo ">>> UI build complete: www/dist/"

# ─────────────────────────────────────────────────────────────────────────────
# Method A — Bootable ISO
# ─────────────────────────────────────────────────────────────────────────────
iso: check-packer
	@echo ">>> Building bootable ISO (Method A)..."
	@$(PACKER_BIN) build \
		-var "version=$(VERSION)" \
		-var "install_path=$(INSTALL_PATH)" \
		-var "dm_user=$(DM_USER)" \
		-var "dm_group=$(DM_GROUP)" \
		packer/iso.pkr.hcl
	@echo ">>> ISO ready: dist/docmaster-$(VERSION).iso"

# ─────────────────────────────────────────────────────────────────────────────
# Method B — LXC Container Template
# ─────────────────────────────────────────────────────────────────────────────
lxc: check-packer
	@echo ">>> Building LXC container template (Method B)..."
	@$(PACKER_BIN) build \
		-var "version=$(VERSION)" \
		-var "install_path=$(INSTALL_PATH)" \
		packer/lxc.pkr.hcl
	@echo ">>> LXC template ready: dist/docmaster-$(VERSION)-lxc.tar.zst"

# ─────────────────────────────────────────────────────────────────────────────
# Method C — Bash Installer Script
# ─────────────────────────────────────────────────────────────────────────────
installer:
	@echo ">>> Building installer bundle (Method C)..."
	@mkdir -p $(DIST_DIR)/installer-$(VERSION)
	@cp scripts/dm-install.sh $(DIST_DIR)/installer-$(VERSION)/
	@# Bundle vendored packages (requires local mirror configured)
	@./build/bundle-deps.sh $(VERSION)
	@tar -czf $(DIST_DIR)/docmaster-$(VERSION)-installer.tar.gz \
		-C $(DIST_DIR) installer-$(VERSION)/
	@sha256sum $(DIST_DIR)/docmaster-$(VERSION)-installer.tar.gz > \
		$(DIST_DIR)/docmaster-$(VERSION)-installer.tar.gz.sha256
	@echo ">>> Installer ready: dist/docmaster-$(VERSION)-installer.tar.gz"

# ─────────────────────────────────────────────────────────────────────────────
# Method D — Docker Compose (development / pilot)
# ─────────────────────────────────────────────────────────────────────────────
docker:
	@echo ">>> Building Docker Compose bundle (Method D)..."
	@docker compose -f docker/docker-compose.yml build \
		--build-arg VERSION=$(VERSION)
	@echo ">>> Docker images built. Start with: docker compose up"

# ─────────────────────────────────────────────────────────────────────────────
# Database schema — apply to local dev PostgreSQL
# ─────────────────────────────────────────────────────────────────────────────
schema:
	@echo ">>> Applying database schema..."
	@psql -U dm_app -d dm_vault -f sql/01_extensions.sql
	@psql -U dm_app -d dm_vault -f sql/02_schemas.sql
	@psql -U dm_app -d dm_vault -f sql/03_enums.sql
	@psql -U dm_app -d dm_vault -f sql/04_tables.sql
	@psql -U dm_app -d dm_vault -f sql/05_indexes.sql
	@psql -U dm_app -d dm_vault -f sql/06_views.sql
	@psql -U dm_app -d dm_vault -f sql/07_seed_config.sql
	@echo ">>> Schema applied."

# ─────────────────────────────────────────────────────────────────────────────
# Alembic migrations
# ─────────────────────────────────────────────────────────────────────────────
migrate:
	@echo ">>> Running Alembic migrations..."
	@cd core && .venv/bin/alembic upgrade head

migrate-new:
	@echo ">>> Creating new migration: $(MSG)"
	@cd core && .venv/bin/alembic revision --autogenerate -m "$(MSG)"

# ─────────────────────────────────────────────────────────────────────────────
# Lint
# ─────────────────────────────────────────────────────────────────────────────
lint:
	@echo ">>> Running linters..."
	@cd core && .venv/bin/ruff check app/ flux/ --fix
	@cd core && .venv/bin/mypy app/ --ignore-missing-imports
	@cd www && npm run lint
	@echo ">>> Lint complete."

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────
test:
	@echo ">>> Running test suite..."
	@cd core && .venv/bin/pytest tests/ -v --tb=short
	@echo ">>> Tests complete."

# ─────────────────────────────────────────────────────────────────────────────
# Dev environment setup
# ─────────────────────────────────────────────────────────────────────────────
dev-setup:
	@echo ">>> Setting up dev environment..."
	@python3.12 -m venv core/.venv
	@core/.venv/bin/pip install --upgrade pip
	@core/.venv/bin/pip install -r core/requirements.txt
	@cd www && npm install
	@cp config/dm.env.template config/dm.env
	@echo ">>> Dev setup complete. Edit config/dm.env before running."

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
check-version:
	@if [ "$(VERSION)" = "" ]; then \
		echo "ERROR: VERSION is required. Usage: make build VERSION=1.0.0"; \
		exit 1; \
	fi

check-packer:
	@which $(PACKER_BIN) > /dev/null 2>&1 || \
		(echo "ERROR: packer not found. Install Packer 1.10.x."; exit 1)

clean:
	@echo ">>> Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR) $(DIST_DIR) www/dist packer_cache output-*
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo ">>> Clean complete."

help:
	@echo ""
	@echo "DocMaster Build Pipeline — v$(VERSION)"
	@echo "────────────────────────────────────────"
	@echo "  make build VERSION=1.0.0 METHOD=iso        Build bootable ISO"
	@echo "  make build VERSION=1.0.0 METHOD=lxc        Build LXC container template"
	@echo "  make build VERSION=1.0.0 METHOD=installer  Build bash installer bundle"
	@echo "  make build VERSION=1.0.0 METHOD=docker     Build Docker Compose bundle"
	@echo "  make build VERSION=1.0.0 METHOD=all        Build all delivery formats"
	@echo ""
	@echo "  make schema                 Apply SQL schema to local dev DB"
	@echo "  make migrate                Run Alembic migrations"
	@echo "  make migrate-new MSG='...'  Create new Alembic migration"
	@echo "  make lint                   Run all linters"
	@echo "  make test                   Run test suite"
	@echo "  make dev-setup              Set up local dev environment"
	@echo "  make clean                  Remove build artifacts"
	@echo ""
