# Integration Tests

Integration tests run the pattern-monitor component inside a real wasmCloud
mesh and verify end-to-end behaviour.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `wash` | wasmCloud CLI — starts a host, deploys the app, publishes messages |
| `redis-server` | Redis instance (default `127.0.0.1:6379`) |
| `redis-cli` | Used by the test script to verify stored vector keys |

Install `wash`:

```bash
curl -s "https://packagecloud.io/install/repositories/wasmcloud/core/script.deb.sh" | sudo bash
sudo apt-get install -y wash
```

## Running

From the repository root:

```bash
./tests/run_integration_test.sh
```

The script will:

1. Build the component if not already built.
2. Start a local wasmCloud host (`wash up`).
3. Deploy the WADM application manifest (`wadm.yaml`).
4. Publish a test JSON message on `pattern.monitor.test`.
5. Wait 5 seconds for the component to encode and store vectors.
6. Check Redis for the expected `semantic:v1:*` and `bundle:v1:*` keys.
7. Report PASS or FAIL.

## Success Criteria

The test passes when every expected Redis key is present after message
delivery, confirming that:

- The component received the JSON message from the NATS messaging provider.
- Each JSON field was encoded into a VSA hypervector.
- Individual semantic vectors are stored under `semantic:v1:{field_name}`.
- The master bundle vector is stored under `bundle:v1:{subject}`.
