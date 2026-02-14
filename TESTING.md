# Testing mqpulse

This directory contains test scripts to verify mqpulse functionality.

## Test Files

### test_single.lua
Single-client automated tests. Runs a suite of tests on one EQ client.

**Usage:**
```
/lua run mqpulse/test_single
```

**What it tests:**
- Pub/Sub messaging
- Hierarchical topic matching
- RPC calls and responses
- RPC timeouts
- Shared state get/set
- Shared state merge
- Deferred execution
- Service registration and discovery

**Expected output:** Pass/fail results for each test, final summary

---

### test_multi.lua
Multi-client integration tests. Must be run on 2+ EQ clients simultaneously.

**Usage:**
1. Launch 2 or more EQ clients on the same server
2. On each client, run: `/lua run mqpulse/test_multi`
3. Watch the output on all clients

**What it tests:**
- Peer presence detection (join/leave events)
- Cross-client pub/sub messaging
- Cross-client RPC calls
- Shared state synchronization across clients
- Service discovery across clients

**Expected behavior:**
- Each client should detect other clients coming online
- Clients should receive pub/sub announcements from peers
- RPC calls between clients should succeed
- Shared state (HP, mana, zone, position) should sync across clients
- Service discovery should find services on all clients

**Monitoring:**
The test prints status updates every 30 seconds showing:
- Number of online peers
- Peer stats (HP, zone)
- Message counts
- RPC call counts

---

## Running Tests Before Release

Before making changes to mqpulse, run both test suites:

1. **Single-client tests:** Quick validation (runs in ~10 seconds)
   ```
   /lua run mqpulse/test_single
   ```
   All tests should pass.

2. **Multi-client tests:** Integration validation (run for 2-3 minutes)
   - Start on 2+ clients
   - Verify presence detection
   - Check that RPC calls succeed
   - Confirm state sync works
   - Stop one client and verify others detect the leave event

## Troubleshooting

**"Tests failed" on single-client:**
- Check that the actors module is loaded (MQ launcher running)
- Verify no conflicting scripts using the same namespace

**Peers not detected in multi-client:**
- Verify all clients are on the same EQ server
- Check `server_filter` is enabled (it is by default)
- Wait 5-10 seconds for heartbeats to exchange
- Verify no firewall blocking local communication

**RPC timeouts:**
- Check target character is running the test script
- Verify both clients can see each other (check peers list)
- Increase timeout if needed: `{ timeout = 10 }`

**State not syncing:**
- Verify presence detection works first
- Check both clients are using same state group name
- Wait for full sync interval (default 30s) or restart both clients
