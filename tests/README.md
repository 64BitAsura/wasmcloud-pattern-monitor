# Integration Tests

Integration tests run the pattern-monitor component inside a **real wasmCloud
mesh** and verify the complete pipeline end-to-end:

```
NATS message  →  component (VSA encode)  →  Redis keys verified
```

## What the test does

| Step | Description |
|------|-------------|
| 1 | Ensures Redis is running — auto-starts `redis-server` if absent |
| 2 | Starts a local wasmCloud host (`wash up`) |
| 3 | Builds the component if no pre-built `.wasm` is found |
| 4 | Deploys the WADM application manifest (`wadm.yaml`) |
| 5 | Waits for the app to reach the `Deployed` state (120 s timeout) |
| 6 | Publishes a test JSON message to `pattern.monitor.integration` |
| 7 | Verifies that all expected Redis keys exist |
| 8 | Cleans up: flushes test keys, undeploys app, stops host, stops Redis (if started) |

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| `wash` | wasmCloud CLI — start host, deploy app | `curl -s "https://packagecloud.io/install/repositories/wasmcloud/core/script.deb.sh" \| sudo bash && sudo apt-get install -y wash` |
| `nats` | Publish test messages to NATS (`wash pub` was removed in wash v0.40+) | `curl -sSL https://github.com/nats-io/natscli/releases/download/v0.1.6/nats-0.1.6-linux-amd64.zip -o /tmp/nats.zip && unzip -q /tmp/nats.zip -d /tmp/nats-dl && sudo cp /tmp/nats-dl/nats-0.1.6-linux-amd64/nats /usr/local/bin/nats` |
| `redis-server` | Redis server (auto-started if not already running) | `sudo apt-get install -y redis-server` |
| `redis-cli` | Key verification | included in `redis-tools` / `redis-server` packages |

## Running

From the repository root:

```bash
./tests/run_integration_test.sh
```

### Environment variable overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_HOST` | `127.0.0.1` | Redis host |
| `REDIS_PORT` | `6379` | Redis port |
| `HOST_READY_TIMEOUT` | `60` | Seconds to wait for wasmCloud host to start |
| `DEPLOY_TIMEOUT` | `120` | Seconds to wait for app to reach Deployed state |
| `PROCESS_WAIT` | `10` | Seconds to wait after publishing the message |

Example with a remote Redis:

```bash
REDIS_HOST=10.0.0.5 REDIS_PORT=6380 ./tests/run_integration_test.sh
```

## Success criteria

The test passes when every expected Redis key exists after message delivery:

| Redis key | Populated by |
|-----------|-------------|
| `semantic:v1:event` | Per-field VSA hypervector (bound key ⊙ value) |
| `semantic:v1:magnitude` | Per-field VSA hypervector |
| `semantic:v1:location` | Per-field VSA hypervector |
| `semantic:v1:depth_km` | Per-field VSA hypervector |
| `bundle:v1:pattern.monitor.integration` | Master bundle (superposition of all fields) |

Values are bincode-serialised `SparseVec` structs.

## Failure diagnostics

On failure the script prints:

1. All keys currently in Redis (`KEYS *`)
2. The last 80 lines of the wasmCloud host log
