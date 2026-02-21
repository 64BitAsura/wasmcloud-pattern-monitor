#!/usr/bin/env bash
# run_integration_test.sh — Full in-mesh integration test for wasmcloud-pattern-monitor.
#
# Tests the complete data pipeline inside a real wasmCloud mesh:
#   1. Redis server ensured running (auto-started if absent)
#   2. wasmCloud host started via `wash up`
#   3. Component built from source if no pre-built artifact exists
#   4. Application deployed via WADM manifest
#   5. Test JSON message published to NATS
#   6. Component processes message: encodes VSA vectors, stores them in Redis
#   7. Redis key verification (semantic vectors + master bundle)
#   8. Full teardown: test keys flushed, app undeployed, host stopped, Redis stopped (if we started it)
#
# Configuration (all overridable via environment variables):
#   REDIS_HOST              Redis host          (default: 127.0.0.1)
#   REDIS_PORT              Redis port          (default: 6379)
#   HOST_READY_TIMEOUT      Seconds to wait for wasmCloud host  (default: 60)
#   DEPLOY_TIMEOUT          Seconds to wait for app deployment  (default: 120)
#   PROCESS_WAIT            Seconds to wait for message processing (default: 10)
#
# Usage (from repository root):
#   ./tests/run_integration_test.sh
set -euo pipefail

# ── Source cargo/local env ────────────────────────────────────────────────────
. "$HOME/.cargo/env" 2>/dev/null || true
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"

# ── Configuration ─────────────────────────────────────────────────────────────
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
HOST_READY_TIMEOUT="${HOST_READY_TIMEOUT:-60}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-120}"
PROCESS_WAIT="${PROCESS_WAIT:-10}"

# Test subject — must match the WADM subscription pattern "pattern.monitor.>"
TEST_SUBJECT="pattern.monitor.integration"
TEST_PAYLOAD='{"event":"earthquake","magnitude":6.2,"location":"Pacific Ocean","depth_km":35}'

# Expected Redis keys (see component/src/lib.rs key naming constants)
EXPECTED_SEMANTIC_KEYS=(
    "semantic:v1:event"
    "semantic:v1:magnitude"
    "semantic:v1:location"
    "semantic:v1:depth_km"
)
EXPECTED_BUNDLE_KEY="bundle:v1:${TEST_SUBJECT}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${CYAN}━━ $* ━━${NC}"; }

# ── Tracked PIDs ──────────────────────────────────────────────────────────────
WASH_PID=""
REDIS_PID_STARTED=""   # set only if we launched Redis ourselves
WASH_LOG=""

# ── Cleanup (always runs on EXIT) ─────────────────────────────────────────────
cleanup() {
    section "Cleanup"

    # Flush the specific test keys we wrote so we don't leave stale data
    if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" PING &>/dev/null 2>&1; then
        for key in "${EXPECTED_SEMANTIC_KEYS[@]}" "$EXPECTED_BUNDLE_KEY"; do
            redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "$key" &>/dev/null || true
        done
        info "Test keys flushed from Redis"
    fi

    # Undeploy and remove the WADM application
    wash app undeploy pattern-monitor-app --timeout-ms 15000 2>/dev/null || true
    wash app delete  pattern-monitor-app --timeout-ms 15000 2>/dev/null || true

    # Shut down the wasmCloud host
    wash down 2>/dev/null || true
    if [[ -n "$WASH_PID" ]]; then
        kill "$WASH_PID" 2>/dev/null || true
    fi
    info "wasmCloud host stopped"

    # Stop Redis only if this script started it
    if [[ -n "$REDIS_PID_STARTED" ]]; then
        kill "$REDIS_PID_STARTED" 2>/dev/null || true
        info "Redis server stopped (PID $REDIS_PID_STARTED)"
    fi

    info "Cleanup complete"
}

trap cleanup EXIT

# ── Helper: poll a command until it succeeds or times out ─────────────────────
wait_for() {
    local label="$1"
    local timeout="$2"
    local cmd="$3"
    info "Waiting for: ${label} (up to ${timeout}s)..."
    for (( i=1; i<=timeout; i++ )); do
        if eval "$cmd" &>/dev/null 2>&1; then
            info "  ✓ Ready after ${i}s"
            return 0
        fi
        sleep 1
    done
    error "Timed out after ${timeout}s waiting for: ${label}"
    return 1
}

# ── 1. Prerequisites ───────────────────────────────────────────────────────────
section "1 · Prerequisites"

if ! command -v wash &>/dev/null; then
    error "wash CLI not found."
    error "Install: curl -s 'https://packagecloud.io/install/repositories/wasmcloud/core/script.deb.sh' | sudo bash && sudo apt-get install -y wash"
    exit 1
fi

# We need at least one of redis-cli or redis-server
if ! command -v redis-cli &>/dev/null && ! command -v redis-server &>/dev/null; then
    error "Neither redis-cli nor redis-server found. Install Redis (e.g. sudo apt-get install -y redis-tools redis-server)."
    exit 1
fi

# nats CLI is used to publish test messages (wash pub was removed in wash v0.40+)
if ! command -v nats &>/dev/null; then
    error "nats CLI not found. Install from https://github.com/nats-io/natscli/releases"
    error "  curl -sSL https://github.com/nats-io/natscli/releases/download/v0.1.6/nats-0.1.6-linux-amd64.zip -o /tmp/nats.zip"
    error "  unzip /tmp/nats.zip -d /tmp/nats-dl && sudo cp /tmp/nats-dl/nats-0.1.6-linux-amd64/nats /usr/local/bin/nats"
    exit 1
fi

info "wash: $(wash --version 2>&1 | head -1)"
info "redis-cli: $(redis-cli --version 2>/dev/null || echo 'not found')"
info "nats: $(nats --version 2>/dev/null)"

# ── 2. Redis lifecycle ─────────────────────────────────────────────────────────
section "2 · Redis"

if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" PING &>/dev/null 2>&1; then
    info "Redis already running at ${REDIS_HOST}:${REDIS_PORT}"
else
    if ! command -v redis-server &>/dev/null; then
        error "Redis is not running and redis-server binary is not found."
        error "Start Redis manually or install it: sudo apt-get install -y redis-server"
        exit 1
    fi
    info "Starting Redis on ${REDIS_HOST}:${REDIS_PORT}..."
    # Run in the background without daemonising so we hold the PID
    redis-server --port "$REDIS_PORT" --bind "$REDIS_HOST" \
        --loglevel warning --save "" --appendonly no &
    REDIS_PID_STARTED=$!
    wait_for "Redis to accept connections" 30 \
        "redis-cli -h '${REDIS_HOST}' -p '${REDIS_PORT}' PING" || exit 1
    info "Redis started (PID ${REDIS_PID_STARTED})"
fi

# ── 3. Component ───────────────────────────────────────────────────────────────
section "3 · Component"

COMPONENT_PATH=$(find component/build -name "*_s.wasm" 2>/dev/null | head -1 || true)
if [[ -z "$COMPONENT_PATH" ]]; then
    warn "No pre-built signed .wasm in component/build; building now (this may take a few minutes)..."
    wash build -p ./component
    COMPONENT_PATH=$(find component/build -name "*_s.wasm" 2>/dev/null | head -1 || true)
fi

if [[ -z "$COMPONENT_PATH" ]]; then
    error "Component wasm not found after build attempt. Check wash build output above."
    exit 1
fi
info "Using component: ${COMPONENT_PATH}"

# ── 4. wasmCloud host ──────────────────────────────────────────────────────────
section "4 · wasmCloud Host"

WASH_LOG=$(mktemp /tmp/wash-pattern-monitor-XXXXXX.log)
info "Starting wasmCloud host (log: ${WASH_LOG})..."
wash up > "$WASH_LOG" 2>&1 &
WASH_PID=$!

wait_for "wasmCloud host to appear in 'wash get hosts'" "$HOST_READY_TIMEOUT" \
    "wash get hosts 2>/dev/null | grep -qE '[A-Z0-9]{20,}'" || {
    error "Last 30 lines of wasmCloud log:"
    tail -30 "$WASH_LOG" 2>/dev/null || true
    exit 1
}

# ── 5. Deploy application ──────────────────────────────────────────────────────
section "5 · Application Deployment"

info "Uploading WADM manifest..."
wash app put wadm.yaml

info "Deploying pattern-monitor-app..."
wash app deploy pattern-monitor-app

info "Waiting for application to reach Deployed state (up to ${DEPLOY_TIMEOUT}s)..."
deployed=false
for (( i=1; i<=(DEPLOY_TIMEOUT/2); i++ )); do
    if wash app status pattern-monitor-app 2>/dev/null | grep -qi "deployed"; then
        info "  ✓ Application Deployed after ~$((i*2))s"
        deployed=true
        break
    fi
    # Abort early on irrecoverable failure
    if wash app status pattern-monitor-app 2>/dev/null | grep -qi "failed"; then
        error "Application entered Failed state — aborting."
        wash app status pattern-monitor-app 2>/dev/null || true
        tail -50 "$WASH_LOG" 2>/dev/null || true
        exit 1
    fi
    sleep 2
done

if [[ "$deployed" != "true" ]]; then
    error "Application did not reach Deployed state within ${DEPLOY_TIMEOUT}s."
    info "Current app status:"
    wash app status pattern-monitor-app 2>/dev/null || true
    info "Last 50 lines of wasmCloud log:"
    tail -50 "$WASH_LOG" 2>/dev/null || true
    exit 1
fi

# Allow providers a moment to establish Redis + NATS connections
info "Pausing 3s for provider link initialisation..."
sleep 3

# ── 6. Publish test message ────────────────────────────────────────────────────
section "6 · Test Message"

info "Publishing JSON payload to subject '${TEST_SUBJECT}'..."
info "  Payload: ${TEST_PAYLOAD}"
# nats pub connects to the embedded NATS server that wash up started on 127.0.0.1:4222
nats pub --server "nats://127.0.0.1:4222" "$TEST_SUBJECT" "$TEST_PAYLOAD"

info "Waiting ${PROCESS_WAIT}s for component to process the message..."
sleep "$PROCESS_WAIT"

# ── 7. Verify Redis keys ───────────────────────────────────────────────────────
section "7 · Key Verification"

info "All keys currently in Redis:"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS '*' 2>/dev/null || true
echo ""

check_key() {
    local key="$1"
    local result
    result=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXISTS "$key" 2>/dev/null || echo "0")
    result="${result//[[:space:]]/}"   # strip any whitespace
    if [[ "$result" == "1" ]]; then
        info "  ✓ ${key}"
        return 0
    else
        error "  ✗ ${key}  (missing)"
        return 1
    fi
}

PASS=true
info "Checking semantic vector keys:"
for key in "${EXPECTED_SEMANTIC_KEYS[@]}"; do
    check_key "$key" || PASS=false
done

info "Checking master bundle key:"
check_key "$EXPECTED_BUNDLE_KEY" || PASS=false

echo ""

# ── 8. Result ──────────────────────────────────────────────────────────────────
section "8 · Result"

if [[ "$PASS" == "true" ]]; then
    info "╔══════════════════════════════════════╗"
    info "║   Integration test  ✅  PASSED       ║"
    info "╚══════════════════════════════════════╝"
    echo ""
    info "End-to-end pipeline verified:"
    info "  JSON message  →  wasmcloud:messaging/handler"
    info "  Fields        →  VSA hypervectors (embeddenator-vsa)"
    info "  Hypervectors  →  bincode bytes (embeddenator-io)"
    info "  Semantic vecs →  Redis  semantic:v1:{field}"
    info "  Master bundle →  Redis  bundle:v1:{subject}"
    exit 0
else
    error "╔══════════════════════════════════════╗"
    error "║   Integration test  ❌  FAILED       ║"
    error "╚══════════════════════════════════════╝"
    echo ""
    error "One or more expected Redis keys were not found."
    error ""
    error "All keys in Redis right now:"
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS '*' 2>/dev/null || true
    error ""
    error "Last 80 lines of wasmCloud host log (${WASH_LOG}):"
    tail -80 "$WASH_LOG" 2>/dev/null || true
    exit 1
fi
