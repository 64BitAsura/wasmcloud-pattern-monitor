#!/usr/bin/env bash
# run_integration_test.sh — Integration tests for the wasmcloud-pattern-monitor component.
#
# Prerequisites (must be available in PATH):
#   - wash   (wasmCloud CLI)
#   - redis-cli (for verifying stored vectors)
#   - redis-server or a running Redis instance on 127.0.0.1:6379
#
# The test:
#   1. Starts a local wasmCloud host via `wash up`.
#   2. Deploys the pattern-monitor application using the wadm manifest.
#   3. Publishes a test JSON message on the NATS subject "pattern.monitor.test".
#   4. Waits for the component to process the message.
#   5. Verifies that the semantic vector and master bundle keys exist in Redis.
#   6. Tears everything down.
set -euo pipefail

# ── Source cargo env if needed ───────────────────────────────────────────────
. "$HOME/.cargo/env" 2>/dev/null || true
export PATH="/usr/local/bin:$PATH"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

info "=== wasmCloud Pattern-Monitor Integration Test ==="
echo ""

# ── Prerequisite checks ───────────────────────────────────────────────────────
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        error "Required command not found: $1"
        exit 1
    fi
}

check_cmd wash
check_cmd redis-cli

info "Prerequisites OK"
echo ""

# ── Cleanup ───────────────────────────────────────────────────────────────────
WASH_PID=""

cleanup() {
    echo ""
    warn "Cleaning up..."

    wash app undeploy pattern-monitor-app 2>/dev/null || true
    wash app delete pattern-monitor-app 2>/dev/null || true

    wash down 2>/dev/null || true
    if [[ -n "$WASH_PID" ]]; then
        kill "$WASH_PID" 2>/dev/null || true
    fi

    info "Cleanup complete"
}

trap cleanup EXIT

# ── Locate built component ────────────────────────────────────────────────────
COMPONENT_PATH=$(find component/build -name "*_s.wasm" 2>/dev/null | head -1)
if [[ -z "$COMPONENT_PATH" ]]; then
    warn "Component wasm not found in component/build; rebuilding..."
    wash build -p ./component
    COMPONENT_PATH=$(find component/build -name "*_s.wasm" 2>/dev/null | head -1)
fi

if [[ -z "$COMPONENT_PATH" ]]; then
    error "Component build failed; no .wasm found"
    exit 1
fi

info "Using component: $COMPONENT_PATH"
echo ""

# ── Start wasmCloud host ──────────────────────────────────────────────────────
info "Starting wasmCloud host..."
WASH_LOG="/tmp/wasmcloud_pattern_monitor.log"
wash up >"$WASH_LOG" 2>&1 &
WASH_PID=$!

info "Waiting for wasmCloud host to be ready..."
for i in $(seq 1 30); do
    if wash get hosts 2>/dev/null | grep -qE "^  [A-Z0-9]{56}"; then
        break
    fi
    sleep 1
done

info "wasmCloud host started"
echo ""

# ── Deploy application ────────────────────────────────────────────────────────
info "Deploying pattern-monitor application..."
wash app put wadm.yaml
wash app deploy pattern-monitor-app

info "Waiting for application to reach deployed state..."
for i in $(seq 1 60); do
    STATUS=$(wash app status pattern-monitor-app 2>/dev/null | grep -i "deployed\|running" || true)
    if [[ -n "$STATUS" ]]; then
        info "Application deployed successfully"
        break
    fi
    sleep 2
done

echo ""

# ── Publish a test JSON message ───────────────────────────────────────────────
TEST_PAYLOAD='{"event":"earthquake","magnitude":6.2,"location":"Pacific Ocean","depth_km":35}'
info "Publishing test message to 'pattern.monitor.test'..."
wash pub pattern.monitor.test "$TEST_PAYLOAD"

info "Waiting 5 s for component to process the message..."
sleep 5

# ── Verify Redis keys ─────────────────────────────────────────────────────────
info "Verifying Redis keys..."
echo ""

REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"

check_key() {
    local key="$1"
    local result
    result=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXISTS "$key" 2>/dev/null || echo "0")
    if [[ "$result" == "1" ]]; then
        info "  ✓ Key exists: $key"
        return 0
    else
        error "  ✗ Key missing: $key"
        return 1
    fi
}

PASS=true

# Expected semantic vector keys
for field in "event" "magnitude" "location" "depth_km"; do
    check_key "semantic:v1:${field}" || PASS=false
done

# Expected master bundle key
check_key "bundle:v1:pattern.monitor.test" || PASS=false

echo ""

# ── Result ────────────────────────────────────────────────────────────────────
if [[ "$PASS" == "true" ]]; then
    info "=== Integration test PASSED ==="
    echo ""
    info "The component successfully:"
    info "  - Received the JSON message via wasmcloud:messaging"
    info "  - Encoded each field into a VSA hypervector (embeddenator-vsa)"
    info "  - Serialised vectors to bincode (embeddenator-io)"
    info "  - Stored semantic vectors in Redis (wasi:keyvalue)"
    info "  - Bundled all vectors and stored the master bundle in Redis"
    exit 0
else
    error "=== Integration test FAILED ==="
    echo ""
    error "One or more expected Redis keys were not found."
    error "Last 50 lines of wasmCloud host log:"
    tail -50 "$WASH_LOG" 2>/dev/null || true
    exit 1
fi
