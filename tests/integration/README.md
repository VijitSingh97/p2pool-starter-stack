# Integration tests (`tests/integration/`)

End-to-end suite that drives a real, already-provisioned Pithead server through the config matrix
and asserts the stack behaves (issue
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

```
run.sh         entry point — connects (SSH or --local) and runs the matrix (+ lifecycle,
               cross-version upgrade, fault, and XvB routing phases)
scenarios.sh   the declarative config matrix (data, not code)
lib.sh         shared helpers: target I/O, assertions, readiness waiters, redaction
live-gates.sh  release readiness, cross-version continuity, and real XvB route/restore gates
live-*-support.sh  private candidate/state, durable supervision, rollback, and XvB helpers
selftest.sh    pure-logic self-test (no server) — runs in CI on every PR
fakes/         controllable fake monerod/Tari + a contract test pointing the REAL clients at
               them (tier 2; runs in CI, no docker)
mini-stack/    docker overlay running the real dashboard + docker-control vs the fakes, with a
               scenario runner for hold/release + reject/readmit (tier 3; needs docker)
```

The live matrix here is tier 4 of the broader plan. See
[`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md) for all four tiers and the full
scenario catalog.

Quick start:

```bash
# Against a remote box over SSH
make test-integration ARGS="--host miner@10.0.0.5 --dir pithead"

# On the box itself
./run.sh --local --dir /home/miner/pithead --lifecycle

# Combined cross-version + real XvB controller gate (old images already running)
# The signed candidate archive must contain PITHEAD_COMMIT with <new-40-hex-sha>.
./run.sh --local --dir /srv/pithead/current --workers 2 --safety-backup \
  --image-upgrade <old-40-hex-sha> <new-40-hex-sha> \
  --candidate-bundle <candidate.tar.gz> <candidate.sig> <trusted-cosign.pub> \
  --lifecycle --xvb-routing-smoke

# Just the pure-logic checks (no server)
make test-integration-selftest
```

Full guide — provisioning the box, the safety model, the matrix, artifacts, and CI/release
wiring — is in [`docs/dev/integration-testing.md`](../../docs/dev/integration-testing.md).
