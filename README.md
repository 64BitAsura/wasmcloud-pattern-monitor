# wasmCloud Pattern Encoder

A wasmCloud component that ingests JSON message streams from a NATS messaging
provider, encodes each message's fields as
[Vector Symbolic Architecture (VSA)](https://github.com/tzervas/embeddenator-vsa)
hypervectors, and stores the results in a Redis-backed key-value store.

## Architecture

```
NATS Subject                  wasmCloud Host
pattern.monitor.>  ──────►  ┌────────────────────────────────────────┐
                             │  pattern-monitor component              │
                             │                                        │
                             │  1. Parse JSON body                    │
                             │  2. Encode each field → SparseVec (VSA)│
                             │  3. Bind key-vec ⊙ value-vec           │
                             │  4. Persist per-field semantic vectors │
                             │  5. Bundle all vecs → master bundle    │
                             │  6. Persist master bundle              │
                             └──────────────┬─────────────────────────┘
                                            │  wasi:keyvalue/store
                                            ▼
                                       Redis DB
                            semantic:v1:{field}  →  bincode(SparseVec)
                            bundle:v1:{subject}  →  bincode(SparseVec)
```

## Crates used

| Crate | Purpose |
|-------|---------|
| `embeddenator-vsa` | VSA operations: `encode_data`, `bind`, `bundle`, `cosine` |
| `embeddenator-io`  | Bincode serialisation of `SparseVec` for Redis storage |
| `embeddenator-retrieval` | Inverted index + two-stage similarity search |

## Capabilities

| Interface | Provider | Purpose |
|-----------|----------|---------|
| `wasmcloud:messaging/handler` | `messaging-nats` | Receive JSON messages |
| `wasi:keyvalue/store`         | `keyvalue-redis`  | Store/retrieve vectors |

## Quick Start

### Prerequisites

```bash
# Install Rust with the wasm32-wasip2 target
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add wasm32-wasip2

# Install the wash CLI
curl -s "https://packagecloud.io/install/repositories/wasmcloud/core/script.deb.sh" | sudo bash
sudo apt-get install -y wash
```

### Build

```bash
wash build -p ./component
```

### Deploy

```bash
# Start a local wasmCloud host
wash up &

# Deploy the application
wash app put wadm.yaml
wash app deploy pattern-monitor-app
```

### Publish a test message

```bash
wash pub pattern.monitor.test \
  '{"event":"earthquake","magnitude":6.2,"location":"Pacific Ocean"}'
```

### Inspect stored vectors in Redis

```bash
redis-cli keys "semantic:v1:*"
redis-cli keys "bundle:v1:*"
```

## Development

```bash
# Format
cargo fmt --manifest-path component/Cargo.toml

# Lint
cargo clippy --manifest-path component/Cargo.toml --target wasm32-wasip2 -- -D warnings

# Unit tests (native target)
cargo test --manifest-path component/Cargo.toml --lib
```

## Testing

See [tests/README.md](tests/README.md) for integration test instructions.

## CI

CI is defined in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) and
runs three jobs on every push/PR to `main`:

| Job | Description |
|-----|-------------|
| `check` | `cargo fmt` + `cargo clippy` on the wasm32-wasip2 target |
| `build` | `wash build` — produces the signed `.wasm` component |
| `test` | Native `cargo test --lib` unit tests |
| `integration-test` | Full in-mesh test via `./tests/run_integration_test.sh` (requires `build`) |
