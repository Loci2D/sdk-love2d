# ADR 0003: Uplink MoveIntent Reliability, Wi-Fi Prediction Horizon Calibration, and Post-Reconnect State Sync

## Status
Accepted (Amends ADR 0001 and ADR 0002)

## Context
Same-room local Wi-Fi playtests running SDK `v0.6.2` against `loci2d` (`v0.6.5-sdk.4`) showed that characters continued to freeze for several seconds after short bursts of wireless contention or packet loss. Controlled local reproduction using an isolated UDP proxy modeling Wi-Fi contention (burst jitter, single/double UDP packet drops, and transient blackouts) identified five interacting flaws across the modular SDK ([`loci/init.lua`](../../loci/init.lua), [`loci/network/transport.lua`](../../loci/network/transport.lua), [`loci/network/protocol.lua`](../../loci/network/protocol.lua), [`loci/netcode/prediction.lua`](../../loci/netcode/prediction.lua)):

1. **Single-Shot UDP `MoveIntent` Uplink Fragility:**
   * Consumer games call `loci.send_move(dx, dy)` only on directional edge changes. Under the `v0.6.2` protocol, `MoveIntent` was emitted once as an unacknowledged UDP datagram.
   * Because the `loci2d` server persists the previous velocity vector until a newer `MoveIntent` arrives (or a crowd-control effect expires), dropping a single uplink `MoveIntent` datagram leaves the server running the stale vector (e.g., `(0, 0)` after holding a key, or continuing to walk after releasing keys) until the player releases and re-presses movement keys.
   * On crowd-control (stun/paralysis/death) expiry, `loci2d` does not buffer rejected intents; a held movement key remained ignored until a fresh `MoveIntent` arrived.

2. **Overly Aggressive `200ms` Prediction Horizon (`prediction_timeout`):**
   * ADR 0002 calibrated `prediction_timeout = 0.200s`. In 30 Hz Wi-Fi playtests, losing ~6 consecutive downstream `WorldState` datagrams (~200ms) or experiencing a brief 250–400ms Wi-Fi CSMA/CA contention stall zeroed client velocity mid-movement, producing repetitive micro-freezes even while the server session remained healthy.

3. **Unpopulated `get_my_entity()` Inside `on_reconnected` & Post-Reconnect Velocity Zero-Lock:**
   * In `loci._handle_world_state`, `loci.on_reconnected(id)` was invoked before the `entities` loop updated `loci.entities[id]`, making `loci.get_my_entity()` return `nil` on first connect/reconnect.
   * During watchdog disconnect (`connection_timeout`), `loci._active_move_dx/dy` were cleared to `0` while `_prediction_starved` was active; once reconnected, if a movement key remained held, client prediction overwrote entity velocity to `0` until the consumer game explicitly detected the timeout/reconnect transition and called `send_move`.

4. **Asymmetric Synthetic Network Simulator:**
   * `simulate_packet_loss` and `simulate_latency` in ADR 0002 affected only inbound packets in `transport.lua`, hiding uplink failures (`MoveIntent` loss, CC desync) during local synthetic testing.

## Decision
We enhance the modular client SDK with uplink reliability, calibrated prediction tolerance, clean reconnect hooks, and symmetric simulation while preserving zero heap allocations on steady-state hot paths:

1. **Active `MoveIntent` Keepalive & Stop Redundancy Tail (`loci/network/transport.lua`, `loci/init.lua`):**
   * Introduce `loci.netcode.intent_keepalive_interval` (default `0.100s` / 100ms): while `_active_move_dx ~= 0 or _active_move_dy ~= 0`, `poll_network` periodically re-emits the active `MoveIntent` datagram over UDP. Under a 100ms cadence, losing a start-move packet recovers automatically within ~100ms without manual key re-press.
   * **CC-Aware Gating (`prediction.is_incapacitated`):** While the local entity is dead, stunned, or paralyzed (`is_dead`, `cur_tick < stunned_until`, `cur_tick < paralyzed_until`), periodic keepalive retransmissions pause and set `_was_incapacitated_with_move = true` to avoid `on_intent_rejected` rejection banner spam. As soon as CC expires while movement remains active, a single immediate recovery `MoveIntent` flushes.
   * Introduce `loci.netcode.stop_redundancy_count` (default `3`): when transitioning from non-zero movement to `(0, 0)` on an active UDP socket, emit up to `stop_redundancy_count - 1` redundant zero-velocity packets spaced `>= 30ms` apart within a `0.5s` window so lost stop packets do not leave the server gliding.

2. **Wi-Fi Prediction Horizon Calibration (`loci/netcode/prediction.lua`, `loci/init.lua`):**
   * Increase default `loci.netcode.prediction_timeout` from `0.200s` to `0.500s` (500ms). At 30 Hz, 500ms absorbs ~15 dropped snapshots / transient Wi-Fi stalls smoothly while still capping worst-case dead-reckoning drift to ~1.5 ticks × speed before stopping ghost walking.

3. **Deferred `on_reconnected` & Timeout-Cleared Velocity Fallback (`loci/init.lua`, `loci/netcode/prediction.lua`):**
   * Move `loci.on_reconnected(id)` invocation to run immediately after `entities` in the snapshot are parsed so `loci.get_my_entity()` is populated and up-to-date.
   * Track `_active_move_cleared_by_timeout`: when watchdog timeout clears `_active_move_dx/dy`, mirror server velocity (`server_vx`, `server_vy`) into `ent.vx/vy` until the consumer explicitly calls `loci.send_move(...)` (which clears the flag), avoiding animation freeze while awaiting consumer input resync.

4. **Symmetric Outbound Network Simulator (`loci/network/protocol.lua`, `loci/network/transport.lua`):**
   * Route outbound packets (except `disconnect` shutdown notifications) through `protocol.deliver_encoded_packet`, applying `simulate_packet_loss` and queuing delayed packets into `_delayed_outbound_queue` using zero-extra-allocation scalar checks when disabled (`<= 0`). `transport.poll_network` drains expired outbound packets each frame.

## Consequences
- **Positive:** Single or bursty uplink UDP `MoveIntent` losses (both start and stop) self-heal in 30–100ms without freezing or sliding.
- **Positive:** 250–400ms Wi-Fi contention stalls no longer halt local movement/animations under the `500ms` horizon.
- **Positive:** CC expiry automatically resumes held movement without spamming `on_intent_rejected` during stun/death.
- **Positive:** Consumers can safely inspect `loci.get_my_entity()` inside `on_reconnected` and trigger input resync cleanly.
- **Positive:** Local synthetic tests (`simulate_packet_loss` / `simulate_latency`) accurately reproduce bidirectional Wi-Fi asymmetry.
- **Positive:** Zero extra steady-state heap allocations per frame when network simulation is disabled.
- **Negative:** Active movement emits ~10 small UDP `MoveIntent` packets/sec (down from only edge changes), which is negligible on LAN/WAN connections.
