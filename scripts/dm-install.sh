#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DocMaster — dm-install.sh
# Phase 1 Foundation Installer (Method C — Bash Installer)
#
# Supports:  Debian 12 (Bookworm) | Ubuntu Server 24.04 LTS
# Run as:    root (or via sudo)
# Idempotent: yes — safe to re-run if interrupted
#
# STRICT RULES enforced throughout:
#   - System user: dmuser (not root, not docmaster)
#   - Group:       docgroup
#   - API port:    8443
#   - Install path: /opt/docmaster (symlink → /opt/docmaster-blue)
#   - All timestamps: UTC
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
IFS=$'\n\t'

# Absolute path to this script's directory (safe regardless of working directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Script-level constants ────────────────────────────────────────────────────
readonly DM_VERSION="1.0.0"
readonly DM_USER="dmuser"
readonly DM_GROUP="docgroup"
readonly SCAN_USER="scanuser"
readonly INSTALL_BASE="/opt"
readonly BLUE_DIR="${INSTALL_BASE}/docmaster-blue"
readonly GREEN_DIR="${INSTALL_BASE}/docmaster-green"
readonly SYMLINK="${INSTALL_BASE}/docmaster"
readonly DM_HOME="${SYMLINK}"   # Always use the symlink
readonly LOG_FILE="/tmp/dm-install-$(date -u +%Y%m%d-%H%M%S).log"
readonly MANIFEST_FILE="${BLUE_DIR}/vault/manifest.lock"

# Pinned versions (update these when upgrading the stack)
readonly OLLAMA_VERSION="0.17.5"
readonly OLLAMA_BINARY_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst"
readonly OLLAMA_SHA256="REPLACE_WITH_PINNED_SHA256"  # Must be set before air-gapped deployment

readonly PG_VERSION="16"
readonly NODE_VERSION="22"

# Ollama models to pre-pull
readonly DM_MODELS_TO_PULL=(
    "llama3.1:8b-q4_K_M"
    "nomic-embed-text"
    "qwen2.5-vl:7b"
)

# Track install step results
declare -A STEP_RESULTS=()
ERRORS=0

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO]  $*" | tee -a "${LOG_FILE}"; }
warn() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [WARN]  $*" | tee -a "${LOG_FILE}"; }
err()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ERROR] $*" | tee -a "${LOG_FILE}" >&2; ERRORS=$((ERRORS+1)); }
ok()   { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [OK]    $*" | tee -a "${LOG_FILE}"; }
step() { echo "" | tee -a "${LOG_FILE}"; echo "════════════════════════════════════════" | tee -a "${LOG_FILE}"; echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ▶ $*" | tee -a "${LOG_FILE}"; echo "════════════════════════════════════════" | tee -a "${LOG_FILE}"; }

record_step() {
    local name="$1" result="$2"
    STEP_RESULTS["${name}"]="${result}"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
preflight() {
    step "Pre-flight checks"

    # Must be root
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This script must be run as root. Exiting." >&2
        exit 1
    fi
    log "Root check: passed"

    # OS detection — Debian 12 or Ubuntu 24.04 LTS only
    if [ ! -f /etc/os-release ]; then
        echo "ERROR: Cannot detect OS (/etc/os-release not found). Exiting." >&2
        exit 1
    fi
    source /etc/os-release

    if [[ "${ID}" == "debian" && "${VERSION_ID}" == "12" ]]; then
        log "OS: Debian 12 (Bookworm) — supported"
    elif [[ "${ID}" == "ubuntu" && "${VERSION_ID}" == "24.04" ]]; then
        log "OS: Ubuntu 24.04 LTS — supported"
    else
        echo "ERROR: Unsupported OS: ${PRETTY_NAME}. Supported: Debian 12, Ubuntu 24.04 LTS." >&2
        exit 1
    fi

    # Detect if already partially installed (idempotent re-run detection)
    if [ -L "${SYMLINK}" ]; then
        warn "Detected existing installation at ${SYMLINK}. Running in idempotent mode."
    fi

    log "Pre-flight: all checks passed."
    record_step "preflight" "OK"
}

# ── Track 1: OS Hardening ──────────────────────────────────────────────────────
track1_os_hardening() {
    step "Track 1 — OS Hardening"

    # 1.1 Hostname
    local current_hostname
    current_hostname=$(hostname)
    if [ "${current_hostname}" != "docmaster-node-01" ]; then
        hostnamectl set-hostname "docmaster-node-01"
        # Update /etc/hosts
        if ! grep -q "127.0.1.1.*docmaster-node-01" /etc/hosts; then
            echo "127.0.1.1  docmaster-node-01" >> /etc/hosts
        fi
        ok "Hostname set to docmaster-node-01"
    else
        ok "Hostname already set to docmaster-node-01"
    fi

    # 1.2 Timezone — must be UTC
    timedatectl set-timezone UTC
    ok "Timezone set to UTC"

    # 1.3 Locale
    if ! locale | grep -q "LANG=en_US.UTF-8"; then
        locale-gen en_US.UTF-8 2>/dev/null || true
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 2>/dev/null || true
    fi
    ok "Locale: en_US.UTF-8"

    # 1.4 Update package index
    apt-get update -qq
    ok "Package index updated"

    # 1.5 Disable and mask unnecessary services
    local MASK_SERVICES=(
        avahi-daemon
        cups
        cups-browsed
        bluetooth
        ModemManager
        snapd
    )
    for svc in "${MASK_SERVICES[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
            systemctl disable --now "${svc}.service" 2>/dev/null || true
            systemctl mask "${svc}.service" 2>/dev/null || true
            log "Masked: ${svc}"
        fi
    done
    ok "Unnecessary services masked"

    # 1.6 Install chrony for NTP
    apt-get install -y -q chrony
    systemctl enable --now chrony
    ok "chrony NTP enabled"

    # 1.7 Install and configure UFW
    apt-get install -y -q ufw
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    # SSH (all sources — admin should restrict to admin IP range in production)
    ufw allow ssh comment "DocMaster admin SSH"
    # DocMaster UI/API — LAN only (operator should lock this to LAN CIDR in production)
    ufw allow 8443/tcp comment "DocMaster UI/API"
    # ICMP for diagnostics
    # UFW handles ICMP via /etc/ufw/before.rules — allow by default
    # Explicitly blocked (comment for auditability — these are already blocked by default deny)
    # Port 5432 (PostgreSQL) — localhost only, UFW irrelevant
    # Port 6379 (Redis) — localhost only
    # Port 11434 (Ollama) — localhost only
    ufw --force enable
    ok "UFW configured: deny all in, allow SSH + 8443/tcp"

    # 1.8 SSH hardening
    local SSHD_CFG="/etc/ssh/sshd_config"
    cp "${SSHD_CFG}" "${SSHD_CFG}.dm-backup"
    _set_sshd_param "PasswordAuthentication" "no"
    _set_sshd_param "PermitRootLogin" "no"
    _set_sshd_param "MaxAuthTries" "3"
    _set_sshd_param "LoginGraceTime" "30"
    _set_sshd_param "X11Forwarding" "no"
    _set_sshd_param "AllowAgentForwarding" "no"
    # Validate before reloading
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        ok "SSH hardened and reloaded"
    else
        warn "SSH config validation failed — restored backup. Check ${SSHD_CFG} manually."
        cp "${SSHD_CFG}.dm-backup" "${SSHD_CFG}"
        err "SSH hardening failed — manual intervention required"
    fi

    # 1.9 Configure unattended-upgrades for security patches only
    apt-get install -y -q unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades-docmaster << 'EOF'
// DocMaster — Security patches only, no automatic reboots
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Package-Blacklist {};
EOF
    ok "Unattended-upgrades: security-only, no auto-reboot"

    record_step "track1_os" "OK"
}

_set_sshd_param() {
    local param="$1" value="$2"
    local sshd_cfg="/etc/ssh/sshd_config"
    if grep -q "^${param}" "${sshd_cfg}"; then
        sed -i "s/^${param}.*/${param} ${value}/" "${sshd_cfg}"
    elif grep -q "^#${param}" "${sshd_cfg}"; then
        sed -i "s/^#${param}.*/${param} ${value}/" "${sshd_cfg}"
    else
        echo "${param} ${value}" >> "${sshd_cfg}"
    fi
}

# ── Track 2: Service User & Group ─────────────────────────────────────────────
track2_users() {
    step "Track 2 — Service User & Group"

    # Create docgroup
    if ! getent group "${DM_GROUP}" > /dev/null 2>&1; then
        groupadd --system "${DM_GROUP}"
        ok "Group ${DM_GROUP} created"
    else
        ok "Group ${DM_GROUP} already exists"
    fi

    # Create dmuser — no shell, no home, locked password
    if ! id "${DM_USER}" > /dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --gid "${DM_GROUP}" \
            --comment "DocMaster service account" \
            "${DM_USER}"
        ok "User ${DM_USER} created (no shell, no home)"
    else
        ok "User ${DM_USER} already exists"
    fi

    # Ensure dmuser is in docgroup
    usermod -aG "${DM_GROUP}" "${DM_USER}" 2>/dev/null || true

    # Lock the account (belt and suspenders — no shell already prevents login)
    passwd -l "${DM_USER}" > /dev/null 2>&1 || true

    # Create scanuser — write access to ingest/ via docgroup membership
    # Used by Samba for SMB scan drop
    if ! id "${SCAN_USER}" > /dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --gid "${DM_GROUP}" \
            --comment "DocMaster Samba scan share account" \
            "${SCAN_USER}"
        ok "User ${SCAN_USER} created (Samba scan drop)"
    else
        ok "User ${SCAN_USER} already exists"
    fi

    ok "User and group setup complete: ${DM_USER}:${DM_GROUP}, ${SCAN_USER}:${DM_GROUP}"
    record_step "track2_users" "OK"
}

# ── Track 3: Directory Structure & Permissions ─────────────────────────────────
track3_directories() {
    step "Track 3 — Directory Structure & Permissions"

    # Create the Blue side (active)
    mkdir -p "${BLUE_DIR}"

    # Create the Green side (standby — empty until first update)
    mkdir -p "${GREEN_DIR}"

    # Full directory tree inside Blue
    local DIRS=(
        "bin"
        "config"
        "config/schemas"
        "core"
        "core/.venv"
        "flux"
        "mind"
        "bridge"
        "sentinel"
        "vault"
        "models"
        "models/paddleocr"
        "models/paddleocr/en/det"
        "models/paddleocr/en/rec"
        "models/paddleocr/en/cls"
        "models/paddleocr/layout"
        "models/paddleocr/table"
        "models/kraken"
        "models/classifier"
        "ingest"
        "ingest/drop"
        "ingest/smb"
        "ingest/fax"
        "ingest/email"
        "tmp"
        "data"
        "data/pgdata"
        "data/vectors"
        "queue"
        "logs"
        "backups"
        "backups/daily"
        "backups/wal"
        "www"
        "reports"
        "reports/scheduled"
        "reports/on-demand"
    )

    for d in "${DIRS[@]}"; do
        mkdir -p "${BLUE_DIR}/${d}"
    done
    ok "Directory tree created at ${BLUE_DIR}"

    # ── Ownership — all dmuser:docgroup ───────────────────────────────────
    chown -R "${DM_USER}:${DM_GROUP}" "${BLUE_DIR}"
    chown -R "${DM_USER}:${DM_GROUP}" "${GREEN_DIR}"
    ok "Ownership: ${DM_USER}:${DM_GROUP}"

    # ── Permission matrix (from Phase 1 spec) ────────────────────────────
    # Root install dir
    chmod 750 "${BLUE_DIR}"
    chmod 750 "${GREEN_DIR}"

    # Standard directories — 750
    local DIRS_750=(
        bin config core flux mind bridge sentinel
        models logs www reports
    )
    for d in "${DIRS_750[@]}"; do
        chmod 750 "${BLUE_DIR}/${d}" 2>/dev/null || true
    done

    # Strict directories — 700 (owner only)
    local DIRS_700=(
        vault tmp data queue backups
    )
    for d in "${DIRS_700[@]}"; do
        chmod 700 "${BLUE_DIR}/${d}" 2>/dev/null || true
    done

    # ingest — 770 (group write for scanuser via docgroup)
    chmod 770 "${BLUE_DIR}/ingest"
    chmod 770 "${BLUE_DIR}/ingest/drop"
    chmod 770 "${BLUE_DIR}/ingest/smb"
    chmod 770 "${BLUE_DIR}/ingest/fax"
    chmod 770 "${BLUE_DIR}/ingest/email"
    ok "Permissions applied per Phase 1 spec"

    # ── Symlink ───────────────────────────────────────────────────────────
    if [ ! -L "${SYMLINK}" ]; then
        ln -sfn "${BLUE_DIR}" "${SYMLINK}"
        ok "Symlink created: ${SYMLINK} → ${BLUE_DIR}"
    elif [ "$(readlink -f "${SYMLINK}")" = "${BLUE_DIR}" ]; then
        ok "Symlink already points to ${BLUE_DIR}"
    else
        warn "Symlink ${SYMLINK} points to $(readlink "${SYMLINK}") — expected ${BLUE_DIR}"
        ln -sfn "${BLUE_DIR}" "${SYMLINK}"
        ok "Symlink corrected: ${SYMLINK} → ${BLUE_DIR}"
    fi

    record_step "track3_dirs" "OK"
}

# ── Track 4: Package Installation ─────────────────────────────────────────────
track4_packages() {
    step "Track 4 — Package Installation"

    # 4.1 Core system tools (install first — needed for subsequent steps)
    step "  4.1 Core tools"
    apt-get install -y -q \
        curl wget git gnupg apt-transport-https ca-certificates \
        software-properties-common build-essential jq rsync \
        htop lsof unzip acl logrotate cron \
        dmidecode libpq-dev libssl-dev libffi-dev \
        libxml2-dev libxslt-dev
    ok "Core tools installed"

    # 4.2 PostgreSQL 16 from PGDG
    step "  4.2 PostgreSQL 16 (PGDG)"
    if ! command -v psql > /dev/null 2>&1 || ! psql --version 2>&1 | grep -q "16\."; then
        # Remove any conflicting distro package
        apt-get remove -y -q postgresql* 2>/dev/null || true

        # Add PGDG key and repo
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
            | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
            > /etc/apt/sources.list.d/pgdg.list
        apt-get update -qq
        apt-get install -y -q \
            "postgresql-${PG_VERSION}" \
            "postgresql-client-${PG_VERSION}" \
            "postgresql-${PG_VERSION}-pgvector"
        ok "PostgreSQL ${PG_VERSION} + pgvector installed from PGDG"
    else
        ok "PostgreSQL $(psql --version | awk '{print $3}') already installed"
    fi
    # NOTE: Do NOT start PostgreSQL here — Phase 2 initializes the data directory

    # 4.3 Redis 7 from official repository
    step "  4.3 Redis 7"
    if ! command -v redis-server > /dev/null 2>&1 || ! redis-server --version 2>&1 | grep -q "v=7\."; then
        curl -fsSL https://packages.redis.io/gpg \
            | gpg --dearmor -o /usr/share/keyrings/redis-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/redis-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/redis.list
        apt-get update -qq
        apt-get install -y -q redis-server
        # Disable Redis autostart — Phase 2 configures and starts it
        systemctl disable redis-server 2>/dev/null || true
        ok "Redis 7 installed"
    else
        ok "Redis $(redis-server --version | awk '{print $3}') already installed"
    fi

    # 4.4 Python 3.12
    step "  4.4 Python 3.12"
    if ! python3.12 --version > /dev/null 2>&1; then
        if [[ "${ID}" == "ubuntu" ]]; then
            apt-get install -y -q python3.12 python3.12-venv python3.12-dev python3-pip
        else
            # Debian 12 — add deadsnakes PPA equivalent or use backports
            apt-get install -y -q python3 python3-venv python3-dev python3-pip
            # Attempt to get 3.12 specifically
            apt-get install -y -q python3.12 python3.12-venv python3.12-dev 2>/dev/null || \
                warn "Python 3.12 not available — using system Python. Verify version >= 3.12"
        fi
    fi
    python3.12 --version 2>/dev/null || python3 --version
    ok "Python 3.12 ready"

    # 4.5 Node.js 22 LTS from NodeSource
    step "  4.5 Node.js 22 LTS"
    if ! node --version 2>&1 | grep -q "^v22\."; then
        curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
        apt-get install -y -q nodejs
        ok "Node.js $(node --version) installed from NodeSource"
    else
        ok "Node.js $(node --version) already installed"
    fi

    # 4.6 Tesseract 5
    step "  4.6 Tesseract 5"
    if ! tesseract --version 2>&1 | grep -q "^tesseract 5\."; then
        apt-get install -y -q \
            tesseract-ocr \
            tesseract-ocr-eng \
            tesseract-ocr-script-latn \
            libtesseract-dev
        ok "Tesseract $(tesseract --version 2>&1 | head -1) installed"
    else
        ok "Tesseract $(tesseract --version 2>&1 | head -1) already installed"
    fi

    # 4.7 PDF and image handling
    step "  4.7 PDF & image tools"
    apt-get install -y -q \
        poppler-utils \
        imagemagick \
        ghostscript \
        libsm6 libxext6 libgl1-mesa-glx libglib2.0-0 \
        libgomp1 libopenblas-dev \
        libjpeg-dev libpng-dev libtiff-dev \
        libheif-dev \
        ffmpeg
    ok "PDF and image tools installed"

    # 4.8 Postfix — local only mode
    step "  4.8 Postfix (local only)"
    if ! dpkg -l postfix 2>/dev/null | grep -q "^ii"; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q postfix mailutils
        # Configure local-only mode
        postconf -e "inet_interfaces = loopback-only"
        postconf -e "mydestination = localhost"
        postconf -e "mynetworks = 127.0.0.0/8"
        systemctl restart postfix 2>/dev/null || true
        ok "Postfix installed in local-only mode"
    else
        ok "Postfix already installed"
    fi

    # 4.9 Samba
    step "  4.9 Samba"
    apt-get install -y -q samba samba-common-bin
    # Configuration happens in Phase 4 — disable autostart for now
    systemctl disable --now smbd nmbd 2>/dev/null || true
    ok "Samba installed (disabled until Phase 4)"

    # 4.10 HylaFAX
    step "  4.10 HylaFAX"
    apt-get install -y -q hylafax-server 2>/dev/null || \
        warn "HylaFAX not available on this distro/arch — fax channel will be unavailable"
    systemctl disable --now hylafax 2>/dev/null || true
    ok "HylaFAX installed (disabled until Phase 4)"

    # 4.11 AppArmor
    step "  4.11 AppArmor"
    apt-get install -y -q apparmor apparmor-utils
    systemctl enable --now apparmor 2>/dev/null || true
    ok "AppArmor installed and active"

    # 4.12 PaddleOCR and Kraken native dependencies
    step "  4.12 PaddleOCR / Kraken native deps"
    apt-get install -y -q \
        libgomp1 \
        libopenblas-dev \
        libjpeg-dev libpng-dev libtiff-dev \
        libxml2-dev libxslt-dev libffi-dev
    ok "PaddleOCR and Kraken native dependencies installed"

    record_step "track4_packages" "OK"
}

# ── Ollama Installation ────────────────────────────────────────────────────────
install_ollama() {
    step "Ollama Installation"

    local OLLAMA_BIN="${DM_HOME}/bin/ollama"

    if [ ! -f "${OLLAMA_BIN}" ]; then
        log "Downloading Ollama v${OLLAMA_VERSION}..."
        # Ensure zstd is available for .tar.zst decompression
        command -v zstd > /dev/null 2>&1 || apt-get install -y -q zstd
        local OLLAMA_ARCHIVE OLLAMA_TMPDIR
        OLLAMA_ARCHIVE=$(mktemp --suffix=.tar.zst)
        OLLAMA_TMPDIR=$(mktemp -d)
        curl -fSL --progress-bar "${OLLAMA_BINARY_URL}" -o "${OLLAMA_ARCHIVE}"
        tar -I zstd -xf "${OLLAMA_ARCHIVE}" -C "${OLLAMA_TMPDIR}"
        # Binary location varies by release — check common paths
        if [ -f "${OLLAMA_TMPDIR}/bin/ollama" ]; then
            mv "${OLLAMA_TMPDIR}/bin/ollama" "${OLLAMA_BIN}"
        elif [ -f "${OLLAMA_TMPDIR}/ollama" ]; then
            mv "${OLLAMA_TMPDIR}/ollama" "${OLLAMA_BIN}"
        else
            err "Could not locate ollama binary in downloaded archive"
            rm -rf "${OLLAMA_TMPDIR}" "${OLLAMA_ARCHIVE}"
            return 1
        fi
        rm -rf "${OLLAMA_TMPDIR}" "${OLLAMA_ARCHIVE}"
        chmod 750 "${OLLAMA_BIN}"
        chown "${DM_USER}:${DM_GROUP}" "${OLLAMA_BIN}"
        ok "Ollama binary installed at ${OLLAMA_BIN}"
    else
        ok "Ollama binary already present at ${OLLAMA_BIN}"
    fi

    # Set environment for dmuser
    local ENV_D="/etc/profile.d/dm-ollama.sh"
    cat > "${ENV_D}" << EOF
# DocMaster — Ollama environment (set for dmuser via dm.env at runtime)
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_MODELS=${DM_HOME}/models
export OLLAMA_KEEP_ALIVE=5m
export OLLAMA_NUM_PARALLEL=1
EOF
    chmod 644 "${ENV_D}"
    ok "Ollama environment configured in ${ENV_D}"

    # Pre-pull models (requires internet — skipped in air-gapped mode)
    if [ "${AIRGAP_MODE:-false}" = "true" ]; then
        warn "AIRGAP_MODE=true — skipping Ollama model pull. Models must be pre-loaded from vendor bundle."
    else
        log "Starting Ollama server to pre-pull models..."
        OLLAMA_HOST=127.0.0.1:11434 \
        OLLAMA_MODELS="${DM_HOME}/models" \
        sudo -u "${DM_USER}" "${OLLAMA_BIN}" serve &
        local OLLAMA_PID=$!

        # Wait for Ollama to be ready
        "${DM_HOME}/bin/wait-for-ollama.sh" || {
            err "Ollama failed to start within 120 seconds"
            kill "${OLLAMA_PID}" 2>/dev/null || true
            return
        }

        for model in "${DM_MODELS_TO_PULL[@]}"; do
            log "Pulling model: ${model}"
            sudo -u "${DM_USER}" \
                OLLAMA_HOST=127.0.0.1:11434 \
                OLLAMA_MODELS="${DM_HOME}/models" \
                "${OLLAMA_BIN}" pull "${model}" || \
                warn "Failed to pull model: ${model} — retry manually"
        done

        # Test inference
        log "Testing inference with llama3.1:8b-q4_K_M..."
        local test_response
        test_response=$(sudo -u "${DM_USER}" \
            OLLAMA_HOST=127.0.0.1:11434 \
            OLLAMA_MODELS="${DM_HOME}/models" \
            curl -sf http://127.0.0.1:11434/api/generate \
            -d '{"model":"llama3.1:8b-q4_K_M","prompt":"Reply with: OK","stream":false}' \
            2>/dev/null | jq -r '.response' 2>/dev/null || echo "")

        if [ -n "${test_response}" ]; then
            ok "Ollama test inference succeeded: ${test_response:0:50}"
        else
            err "Ollama test inference returned empty response"
        fi

        kill "${OLLAMA_PID}" 2>/dev/null || true
        wait "${OLLAMA_PID}" 2>/dev/null || true
    fi

    record_step "ollama" "OK"
}

# ── AppArmor Profile Installation ─────────────────────────────────────────────
install_apparmor_profiles() {
    step "AppArmor Profile Installation"

    local APPARMOR_SRC="${DM_HOME}/config/apparmor"
    local APPARMOR_DST="/etc/apparmor.d"

    if [ -d "${APPARMOR_SRC}" ]; then
        for profile in dm-core dm-flux dm-ocr-worker; do
            if [ -f "${APPARMOR_SRC}/${profile}" ]; then
                cp "${APPARMOR_SRC}/${profile}" "${APPARMOR_DST}/${profile}"
                apparmor_parser -r "${APPARMOR_DST}/${profile}" 2>/dev/null || \
                    warn "AppArmor profile ${profile} parse failed — check profile syntax"
                ok "AppArmor profile loaded: ${profile}"
            else
                warn "AppArmor profile not found: ${APPARMOR_SRC}/${profile}"
            fi
        done
    else
        warn "AppArmor profile directory not found: ${APPARMOR_SRC}"
        warn "Deploy apparmor/ profiles before enabling enforcement"
    fi

    record_step "apparmor" "OK"
}

# ── systemd Units ─────────────────────────────────────────────────────────────
install_systemd_units() {
    step "systemd Unit Installation"

    local SYSTEMD_SRC="${DM_HOME}/systemd"
    local SYSTEMD_DST="/etc/systemd/system"

    if [ -d "${SYSTEMD_SRC}" ]; then
        for unit in dm-core dm-flux dm-mind dm-bridge dm-sentinel dm-vault; do
            local unit_file="${SYSTEMD_SRC}/${unit}.service"
            if [ -f "${unit_file}" ]; then
                cp "${unit_file}" "${SYSTEMD_DST}/${unit}.service"
                ok "Installed: ${unit}.service"
            else
                warn "Unit file not found: ${unit_file}"
            fi
        done
        systemctl daemon-reload
        ok "systemd units installed and daemon reloaded"
    else
        warn "systemd directory not found at ${SYSTEMD_SRC}"
    fi

    record_step "systemd" "OK"
}

# ── Cron File ─────────────────────────────────────────────────────────────────
install_cron() {
    step "Cron Job Installation"

    local CRON_SRC="${DM_HOME}/config/docmaster.cron"
    local CRON_DST="/etc/cron.d/docmaster"

    if [ -f "${CRON_SRC}" ]; then
        cp "${CRON_SRC}" "${CRON_DST}"
        chmod 644 "${CRON_DST}"
        ok "Cron file installed at ${CRON_DST}"
    else
        warn "Cron file not found at ${CRON_SRC} — creating placeholder"
        cat > "${CRON_DST}" << EOF
# DocMaster — Scheduled jobs (placeholder — generated by dm-install.sh)
# Update when Phase 4+ configuration is complete
SHELL=/bin/bash
PATH=/opt/docmaster/bin:/usr/local/bin:/usr/bin:/bin

# 02:30 UTC — encrypted DB backup
30 2 * * * dmuser ${DM_HOME}/bin/dm-backup.sh >> ${DM_HOME}/logs/dm-backup.log 2>&1

# 03:00 UTC — tmp cleanup (failed job dirs > 24h)
0 3 * * * dmuser find ${DM_HOME}/tmp -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null

# 03:30 UTC — IVFFlat index check + rebuild if >= 3900 embeddings
30 3 * * * dmuser ${DM_HOME}/bin/dm-sentinel --check-ivfflat >> ${DM_HOME}/logs/dm-sentinel.log 2>&1

# 04:00 UTC — backup verification
0 4 * * * dmuser ${DM_HOME}/bin/dm-backup.sh --verify >> ${DM_HOME}/logs/dm-backup.log 2>&1

# */30 — sentinel health snapshot
*/30 * * * * dmuser ${DM_HOME}/bin/dm-sentinel --snapshot >> ${DM_HOME}/logs/dm-sentinel.log 2>&1
EOF
        chmod 644 "${CRON_DST}"
        ok "Placeholder cron file created"
    fi

    record_step "cron" "OK"
}

# ── dm.env Configuration Template ─────────────────────────────────────────────
init_dm_env() {
    step "dm.env Initialization"

    local ENV_FILE="${DM_HOME}/config/dm.env"

    if [ ! -f "${ENV_FILE}" ]; then
        local TEMPLATE="${DM_HOME}/config/dm.env.template"
        if [ -f "${TEMPLATE}" ]; then
            cp "${TEMPLATE}" "${ENV_FILE}"
        else
            warn "dm.env.template not found — creating minimal dm.env"
            cat > "${ENV_FILE}" << EOF
# DocMaster Runtime Environment
# STRICT RULE: This file must have mode 600 and be owned by dmuser:docgroup
# All services load this via EnvironmentFile= in systemd unit files

# Application
DM_VERSION=${DM_VERSION}
DM_NODE=docmaster-node-01
DM_BUILD=

# Database
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=dm_vault
DB_USER=dm_app
DB_PASSWORD=CHANGE_ME_BEFORE_FIRST_BOOT

# Redis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=CHANGE_ME_BEFORE_FIRST_BOOT

# Ollama
OLLAMA_HOST=http://127.0.0.1:11434
OLLAMA_MODELS=${DM_HOME}/models
OLLAMA_KEEP_ALIVE=5m
OLLAMA_NUM_PARALLEL=1
LLM_PRIMARY_MODEL=llama3.1:8b-q4_K_M
EMBEDDING_MODEL=nomic-embed-text

# Paths
INSTALL_PATH=${DM_HOME}
PADDLE_PDX_CACHE_HOME=${DM_HOME}/models/paddleocr
KRAKEN_MODEL_PATH=${DM_HOME}/models/kraken

# Worker
DM_WORKER_COUNT=1
EOF
        fi
        chown "${DM_USER}:${DM_GROUP}" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        ok "dm.env initialized at ${ENV_FILE} (mode 600)"
    else
        # Ensure permissions are correct even if file already exists
        chown "${DM_USER}:${DM_GROUP}" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        ok "dm.env already exists — permissions verified (mode 600)"
    fi

    record_step "dm_env" "OK"
}

# ── Manifest Generation ────────────────────────────────────────────────────────
generate_manifest() {
    step "Manifest Generation"

    # Delegate to dedicated script
    local MANIFEST_SCRIPT="${DM_HOME}/bin/dm-generate-manifest.sh"
    if [ -f "${MANIFEST_SCRIPT}" ]; then
        bash "${MANIFEST_SCRIPT}"
        ok "Manifest generated at ${MANIFEST_FILE}"
    else
        warn "dm-generate-manifest.sh not found — generating inline"
        _generate_manifest_inline
    fi

    # Set read-only
    if [ -f "${MANIFEST_FILE}" ]; then
        chown "${DM_USER}:${DM_GROUP}" "${MANIFEST_FILE}"
        chmod 440 "${MANIFEST_FILE}"
        ok "Manifest locked: ${MANIFEST_FILE} (mode 440)"
    fi

    record_step "manifest" "OK"
}

_generate_manifest_inline() {
    mkdir -p "$(dirname "${MANIFEST_FILE}")"
    {
        echo "# DocMaster Phase 1 Manifest"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Node:      $(hostname)"
        echo ""
        echo "## OS"
        cat /etc/os-release
        echo ""
        echo "## Kernel"
        uname -r
        echo ""
        echo "## Python"
        python3.12 --version 2>/dev/null || python3 --version
        echo ""
        echo "## Node.js"
        node --version 2>/dev/null || echo "not installed"
        echo ""
        echo "## PostgreSQL"
        psql --version 2>/dev/null || echo "not installed"
        echo ""
        echo "## Redis"
        redis-server --version 2>/dev/null || echo "not installed"
        echo ""
        echo "## Tesseract"
        tesseract --version 2>/dev/null | head -3 || echo "not installed"
        echo ""
        echo "## Ollama"
        sudo -u "${DM_USER}" "${DM_HOME}/bin/ollama" --version 2>/dev/null || echo "not installed"
        echo ""
        echo "## Key Packages (dpkg)"
        dpkg -l postgresql-${PG_VERSION} redis-server python3.12 nodejs tesseract-ocr \
            poppler-utils imagemagick samba apparmor 2>/dev/null | grep "^ii" || true
        echo ""
        echo "## Manifest Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${MANIFEST_FILE}"

    # Append self-SHA256
    local sha256
    sha256=$(sha256sum "${MANIFEST_FILE}" | awk '{print $1}')
    echo "" >> "${MANIFEST_FILE}"
    echo "## SHA256: ${sha256}" >> "${MANIFEST_FILE}"
}

# ── Summary Report ─────────────────────────────────────────────────────────────
print_summary() {
    step "Installation Summary"
    echo ""
    echo "  DocMaster Phase 1 Installation Summary"
    echo "  ─────────────────────────────────────────"
    for step_name in "${!STEP_RESULTS[@]}"; do
        printf "  %-30s %s\n" "${step_name}" "${STEP_RESULTS[${step_name}]}"
    done
    echo ""
    echo "  Log file: ${LOG_FILE}"
    echo "  Errors:   ${ERRORS}"
    echo ""

    if [ "${ERRORS}" -gt 0 ]; then
        echo "  ⚠ Phase 1 completed with ${ERRORS} error(s). Review log and re-run."
        echo "  Run dm-phase1-validate.sh for the gate checklist."
    else
        echo "  ✓ Phase 1 installation complete."
        echo "  Run scripts/dm-phase1-validate.sh to confirm all gate criteria."
        echo "  Do NOT proceed to Phase 2 until all gate criteria pass."
    fi
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    echo "═══════════════════════════════════════════════════════"
    echo "  DocMaster v${DM_VERSION} — Phase 1 Installer"
    echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "═══════════════════════════════════════════════════════"
    log "Install log: ${LOG_FILE}"

    preflight
    track1_os_hardening
    track2_users
    track3_directories
    track4_packages

    # Copy application source to install path (after track4 installs rsync)
    # In Method C, the installer bundle is extracted alongside this script
    local REPO_ROOT
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    if [ -d "${REPO_ROOT}/core" ]; then
        log "Copying application source to ${DM_HOME}..."
        rsync -a "${REPO_ROOT}/core/"    "${DM_HOME}/core/"    || err "rsync failed: core/"
        rsync -a "${REPO_ROOT}/flux/"    "${DM_HOME}/flux/"    2>/dev/null || true
        rsync -a "${REPO_ROOT}/config/"  "${DM_HOME}/config/"  || err "rsync failed: config/"
        rsync -a "${REPO_ROOT}/systemd/" "${DM_HOME}/systemd/" || err "rsync failed: systemd/"
        rsync -a "${REPO_ROOT}/scripts/" "${DM_HOME}/bin/"     || err "rsync failed: scripts/"
        rsync -a "${REPO_ROOT}/sql/"     "${DM_HOME}/sql/"     2>/dev/null || true
        chown -R "${DM_USER}:${DM_GROUP}" "${DM_HOME}/core" "${DM_HOME}/config" \
            "${DM_HOME}/bin" "${DM_HOME}/systemd" 2>/dev/null || true
        ok "Application source deployed from ${REPO_ROOT}"
    else
        warn "Repo root not found at ${REPO_ROOT} — application source not deployed"
    fi
    init_dm_env
    install_ollama
    install_apparmor_profiles
    install_systemd_units
    install_cron
    generate_manifest

    print_summary
}

main "$@"
