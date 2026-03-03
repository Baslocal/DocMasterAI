#!/usr/bin/env bash
# DocMaster — wait-for-ollama.sh
# Polls the Ollama health endpoint until it responds HTTP 200.
# Used as ExecStartPost in dm-mind.service to gate dependent services.
#
# Exit codes:
#   0 — Ollama is ready
#   1 — Timeout exceeded (120 seconds)
#
# STRICT RULE: Never use 'exit' without explicit approval in provisioner scripts.
# This script is designed to exit cleanly in both success and timeout cases.

set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
HEALTH_URL="${OLLAMA_HOST}/api/tags"
TIMEOUT_SECONDS=120
POLL_INTERVAL=2
elapsed=0

echo "[wait-for-ollama] Waiting for Ollama at ${HEALTH_URL} (timeout: ${TIMEOUT_SECONDS}s)"

while true; do
    if curl -sf --max-time 3 "${HEALTH_URL}" > /dev/null 2>&1; then
        echo "[wait-for-ollama] Ollama is ready (elapsed: ${elapsed}s)"
        exit 0
    fi

    if [ "${elapsed}" -ge "${TIMEOUT_SECONDS}" ]; then
        echo "[wait-for-ollama] ERROR: Ollama did not respond within ${TIMEOUT_SECONDS}s" >&2
        exit 1
    fi

    sleep "${POLL_INTERVAL}"
    elapsed=$((elapsed + POLL_INTERVAL))
    echo "[wait-for-ollama] Waiting... (${elapsed}s elapsed)"
done
