# ADR 0002: Netcode Packet Loss Resilience, Prediction Horizon and Auto-Reconnection

## Status
Accepted

## Context
Following the implementation of ADR 0001 (Client-Side Prediction and Snapshot Interpolation), physical multi-machine playtests over local Wi-Fi without external internet exposed edge cases under severe packet loss and radio fluctuations:

1. **Phantom / Ghost Walking Through Walls:** When client movement inputs were held during bursty packet loss, client-side prediction continued integrating position frame-by-frame indefinitely. Because map collisions and boundary constraints are enforced authoritatively by the server (`loci2d`), the client avatar walked through walls and drifted off-map without server updates.
2. **Heartbeat / Timeout Mismatch & Zombie Client State:** The SDK heartbeat ping was sent every 2.0s, while the server enforces a 10s inactivity cutoff (`client_timeout_secs = 10`). In lossy Wi-Fi environments, dropping 4–5 UDP pings resulted in server session eviction. Because the client retained `my_entity_id` and continued emitting pings without receiving server responses, it entered a permanent "zombie" state unable to recover without restarting the application.

## Decision
We decided to enhance `loci_client.lua` with netcode resilience safeguards:

1. **Bounded Prediction Horizon (Timeout Cap):**
   * Limit client-side prediction to a maximum window of silence (default `0.200s` / 200ms) without incoming authoritative snapshots.
   * If silence exceeds this threshold, freeze predicted displacement and zero velocity, pinning the avatar to its last valid position until network communication resumes.

2. **Accelerated Heartbeat Interval:**
   * Shorten the client heartbeat ping interval from 2.0s to `0.400s` (~2.5 pings/sec).
   * Over a 10s inactivity window, this increases heartbeat attempts to ~25 pings, requiring extreme sustained packet loss before an accidental server drop occurs.

3. **Client-Side Connection Watchdog & Auto-Reconnection:**
   * Introduce a client inactivity watchdog (default `4.0s`). If no datagrams arrive from the server within this period:
     * Transition session state to disconnected and fire `loci.on_connection_lost(reason)`.
     * Reset `my_entity_id = nil` and clear the snapshot buffer.
     * Automatically trigger re-join attempts with backoff.
     * When the server accepts the join and issues an entity ID, fire `loci.on_reconnected(entity_id)`.

4. **Synthetic Latency and Packet Loss Simulator:**
   * Expose `simulate_packet_loss` and `simulate_latency` directly in `loci.netcode` for local DX and synthetic testing without external network shaping tools.

## Consequences
- **Positive:** Eliminates ghost walking through walls during network hitches; characters stop gracefully.
- **Positive:** Eliminates zombie client states; sessions survive transient drops or auto-reconnect transparently.
- **Positive:** Greatly reduces accidental server timeouts over unstable Wi-Fi.
- **Positive:** Enables game-level UI to react to connection state transitions via standard lifecycle callbacks.
- **Positive:** 100% reusable and game-agnostic across all Loci2D projects.
- **Negative:** Slightly increases background UDP ping traffic (from 0.5 packets/sec to 2.5 packets/sec, which remains negligible on modern LANs).
