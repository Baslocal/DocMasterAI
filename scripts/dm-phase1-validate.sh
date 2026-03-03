#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DocMaster — dm-phase1-validate.sh
# Phase 1 Gate Validation Script
#
# Run after dm-install.sh completes. Every check maps directly to the
# Phase 1 Blueprint validation checklist. Do NOT proceed to Phase 2 until
# this script exits with status 0 (all checks pass).
#
# Usage:  bash scripts/dm-phase1-validate.sh [--strict]
#   --strict: fail on any WARN (default: only fail on ERROR)
#
# Output: human-readable checklist + machine-readable exit code
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

readonly DM_USER="dmuser"
readonly DM_GROUP="docgroup"
readonly SYMLINK="/opt/docmaster"
readonly BLUE_DIR="/opt/docmaster-blue"
readonly DM_HOME="${SYMLINK}"
readonly STRICT="${1:-}"

PASS=0
FAIL=0
WARN_COUNT=0

# ── Output helpers ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; WARN_COUNT=$((WARN_COUNT+1)); }
section() { echo ""; echo "── $* ──────────────────────────────────────────────"; }

check() {
    local desc="$1"
    shift
    if eval "$@" > /dev/null 2>&1; then
        pass "${desc}"
    else
        fail "${desc}"
    fi
}

check_warn() {
    local desc="$1"
    shift
    if eval "$@" > /dev/null 2>&1; then
        pass "${desc}"
    else
        warn "${desc}"
    fi
}

# ── Section 1: OS Baseline ─────────────────────────────────────────────────────
section "OS Baseline"

check  "Hostname: docmaster-node-01" \
    "hostname | grep -q 'docmaster-node-01'"

check  "Timezone: UTC" \
    "timedatectl status | grep -q 'Time zone: UTC'"

check  "NTP: chrony active" \
    "systemctl is-active chrony | grep -q 'active'"

check  "NTP: chrony synchronized" \
    "chronyc tracking | grep -q 'Reference ID'"

check  "UFW: active" \
    "ufw status | grep -q 'Status: active'"

check  "UFW: port 8443 allowed" \
    "ufw status | grep -q '8443'"

check  "UFW: SSH allowed" \
    "ufw status | grep -qi 'ssh\|22'"

check  "SSH: PasswordAuthentication no" \
    "grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config"

check  "SSH: PermitRootLogin no" \
    "grep -q '^PermitRootLogin no' /etc/ssh/sshd_config"

check  "SSH: MaxAuthTries 3" \
    "grep -q '^MaxAuthTries 3' /etc/ssh/sshd_config"

check  "Service masked: avahi-daemon" \
    "systemctl is-enabled avahi-daemon 2>&1 | grep -q 'masked\|not-found'"

check_warn "Service masked: cups" \
    "systemctl is-enabled cups 2>&1 | grep -q 'masked\|not-found'"

check_warn "Service masked: bluetooth" \
    "systemctl is-enabled bluetooth 2>&1 | grep -q 'masked\|not-found'"

check_warn "snapd: removed or masked" \
    "systemctl is-enabled snapd 2>&1 | grep -q 'masked\|not-found' || ! command -v snap"

check  "unattended-upgrades: installed" \
    "dpkg -l unattended-upgrades | grep -q '^ii'"

check  "Locale: en_US.UTF-8" \
    "locale | grep -q 'LANG=en_US.UTF-8'"

# ── Section 2: Users & Groups ───────────────────────────────────────────────────
section "Users & Groups"

check  "Group 'docgroup' exists" \
    "getent group ${DM_GROUP}"

check  "User 'dmuser' exists" \
    "id ${DM_USER}"

check  "dmuser: no login shell" \
    "getent passwd ${DM_USER} | cut -d: -f7 | grep -qE '/(false|nologin)'"

check  "dmuser: no home directory" \
    "getent passwd ${DM_USER} | cut -d: -f6 | grep -q '^/nonexistent\|^$' || [ ! -d \"\$(getent passwd ${DM_USER} | cut -d: -f6)\" ]"

check  "dmuser: member of docgroup" \
    "id ${DM_USER} | grep -q '${DM_GROUP}'"

check  "dmuser: account locked" \
    "passwd -S ${DM_USER} 2>/dev/null | grep -qE 'L|locked'"

check  "scanuser: exists" \
    "id scanuser"

check  "scanuser: member of docgroup" \
    "id scanuser | grep -q '${DM_GROUP}'"

# ── Section 3: Directory Structure ─────────────────────────────────────────────
section "Directory Structure"

check  "Blue dir exists: /opt/docmaster-blue" \
    "[ -d '${BLUE_DIR}' ]"

check  "Symlink exists: /opt/docmaster → /opt/docmaster-blue" \
    "[ -L '${SYMLINK}' ] && [ \"\$(readlink -f '${SYMLINK}')\" = '${BLUE_DIR}' ]"

# Check all required subdirectories
for subdir in bin config core flux mind bridge sentinel vault models ingest tmp data queue logs backups www; do
    check "Dir: ${DM_HOME}/${subdir}" \
        "[ -d '${DM_HOME}/${subdir}' ]"
done

# Ownership checks
check  "Owner: ${DM_HOME} → ${DM_USER}:${DM_GROUP}" \
    "stat -c '%U:%G' '${DM_HOME}' | grep -q '${DM_USER}:${DM_GROUP}'"

# Permission checks — mode 700
for strict_dir in vault tmp data queue backups; do
    check "Mode 700: ${DM_HOME}/${strict_dir}" \
        "[ \"\$(stat -c '%a' '${DM_HOME}/${strict_dir}')\" = '700' ]"
done

# Permission checks — mode 770 (ingest)
check "Mode 770: ${DM_HOME}/ingest" \
    "[ \"\$(stat -c '%a' '${DM_HOME}/ingest')\" = '770' ]"

# Permission checks — mode 750 (all others)
for normal_dir in bin config core logs; do
    check "Mode 750: ${DM_HOME}/${normal_dir}" \
        "[ \"\$(stat -c '%a' '${DM_HOME}/${normal_dir}')\" = '750' ]"
done

# Verify vault is not readable by group
check  "vault/: group cannot traverse (mode 700)" \
    "[ \"\$(stat -c '%a' '${DM_HOME}/vault')\" = '700' ]"

# dm.env permissions
check  "dm.env: exists at ${DM_HOME}/config/dm.env" \
    "[ -f '${DM_HOME}/config/dm.env' ]"

check  "dm.env: mode 600" \
    "[ \"\$(stat -c '%a' '${DM_HOME}/config/dm.env')\" = '600' ]"

check  "dm.env: owned by ${DM_USER}" \
    "stat -c '%U' '${DM_HOME}/config/dm.env' | grep -q '${DM_USER}'"

# ── Section 4: Dependencies ─────────────────────────────────────────────────────
section "Dependencies"

check  "PostgreSQL 16 installed" \
    "psql --version | grep -q ' 16\.'"

check  "pgvector extension package" \
    "dpkg -l 'postgresql-${16:-16}-pgvector' 2>/dev/null | grep -q '^ii' || dpkg -l '*pgvector*' | grep -q '^ii'"

check  "Redis 7 installed" \
    "redis-server --version | grep -q 'v=7\.'"

check  "Python 3.12 installed" \
    "python3.12 --version | grep -q '3\.12'"

check  "Node.js 22 installed" \
    "node --version | grep -q '^v22\.'"

check  "Tesseract 5 installed" \
    "tesseract --version 2>&1 | grep -q 'tesseract 5\.'"

check  "Tesseract eng data installed" \
    "[ -f /usr/share/tessdata/eng.traineddata ]"

check  "pdftoppm (poppler-utils)" \
    "command -v pdftoppm"

check  "imagemagick installed" \
    "command -v convert"

check  "ghostscript installed" \
    "command -v gs"

check  "ffmpeg installed" \
    "command -v ffmpeg"

check  "OpenCV libGL dependency" \
    "ldconfig -p | grep -q 'libGL'"

check  "postfix: installed" \
    "command -v postfix"

check_warn "postfix: local-only mode" \
    "postconf inet_interfaces 2>/dev/null | grep -q 'loopback'"

check  "samba: installed" \
    "command -v smbd"

check_warn "hylafax-server: installed" \
    "command -v faxstat || dpkg -l hylafax-server 2>/dev/null | grep -q '^ii'"

check  "chrony: installed" \
    "command -v chronyc"

check  "ufw: installed" \
    "command -v ufw"

check  "AppArmor: installed" \
    "command -v apparmor_parser"

check  "AppArmor: active" \
    "systemctl is-active apparmor | grep -q 'active'"

check  "jq: installed"    "command -v jq"
check  "curl: installed"  "command -v curl"
check  "rsync: installed" "command -v rsync"
check  "lsof: installed"  "command -v lsof"
check  "htop: installed"  "command -v htop"

# ── Section 5: Ollama ──────────────────────────────────────────────────────────
section "Ollama"

check  "Ollama binary: ${DM_HOME}/bin/ollama" \
    "[ -f '${DM_HOME}/bin/ollama' ]"

check  "Ollama binary: owned by ${DM_USER}:${DM_GROUP}" \
    "stat -c '%U:%G' '${DM_HOME}/bin/ollama' | grep -q '${DM_USER}:${DM_GROUP}'"

check  "Ollama binary: mode 750" \
    "[ \"\$(stat -c '%a' '${DM_HOME}/bin/ollama')\" = '750' ]"

check  "wait-for-ollama.sh: present" \
    "[ -f '${DM_HOME}/bin/wait-for-ollama.sh' ]"

check  "wait-for-ollama.sh: executable" \
    "[ -x '${DM_HOME}/bin/wait-for-ollama.sh' ]"

check  "Ollama models dir: ${DM_HOME}/models" \
    "[ -d '${DM_HOME}/models' ]"

# Check model directories (files present after pull)
for model_dir in llama3.1 nomic-embed-text; do
    check_warn "Model dir present: ${model_dir}" \
        "find '${DM_HOME}/models' -name '*${model_dir}*' | grep -q ."
done

# ── Section 6: Manifest ────────────────────────────────────────────────────────
section "Manifest"

check  "manifest.lock exists: ${DM_HOME}/vault/manifest.lock" \
    "[ -f '${DM_HOME}/vault/manifest.lock' ]"

check  "manifest.lock: mode 440 (read-only)" \
    "[ \"\$(stat -c '%a' '${DM_HOME}/vault/manifest.lock')\" = '440' ]"

check  "manifest.lock: owned by ${DM_USER}:${DM_GROUP}" \
    "stat -c '%U:%G' '${DM_HOME}/vault/manifest.lock' | grep -q '${DM_USER}:${DM_GROUP}'"

check  "manifest.lock: contains SHA256" \
    "grep -q 'SHA256' '${DM_HOME}/vault/manifest.lock'"

check  "manifest.lock: contains OS info" \
    "grep -q 'ID=' '${DM_HOME}/vault/manifest.lock'"

# ── Section 7: AppArmor Profiles ───────────────────────────────────────────────
section "AppArmor Profiles"

for profile in dm-core dm-flux dm-ocr-worker; do
    check_warn "AppArmor profile loaded: ${profile}" \
        "aa-status 2>/dev/null | grep -q '${profile}' || [ -f '/etc/apparmor.d/${profile}' ]"
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  DocMaster Phase 1 Gate Validation — Summary"
echo "═══════════════════════════════════════════════════════"
printf "  %s PASS | %s FAIL | %s WARN\n" "${PASS}" "${FAIL}" "${WARN_COUNT}"
echo ""

if [ "${FAIL}" -gt 0 ]; then
    echo -e "  ${RED}✗ Phase 1 gate FAILED — ${FAIL} check(s) did not pass.${NC}"
    echo "    Resolve all failures before proceeding to Phase 2."
    echo ""
    exit 1
elif [ "${WARN_COUNT}" -gt 0 ] && [ "${STRICT}" = "--strict" ]; then
    echo -e "  ${YELLOW}⚠ Phase 1 gate FAILED in --strict mode — ${WARN_COUNT} warning(s).${NC}"
    echo ""
    exit 1
elif [ "${WARN_COUNT}" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠ Phase 1 gate PASSED with ${WARN_COUNT} warning(s).${NC}"
    echo "    Review warnings — they may indicate non-critical gaps."
    echo "    Proceed to Phase 2 with caution."
    echo ""
    exit 0
else
    echo -e "  ${GREEN}✓ Phase 1 gate PASSED — all ${PASS} checks passed.${NC}"
    echo "    System is ready for Phase 2: Database & Queue Layer."
    echo ""
    exit 0
fi
