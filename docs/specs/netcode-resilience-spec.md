# Technical Specification: Netcode Resilience, Prediction Horizon & Auto-Reconnection
**Module:** `loci/init.lua` / `loci_client.lua` (`sdk-love2d`)  
**Author:** Antigravity / Loci2D Team  
**Status:** Accepted  
**Compatibility:** `loci2d` v0.6.x+  
**Architecture Records:** [ADR 0002](../adr/en/0002-netcode-packet-loss-resilience-and-auto-reconnect.md), [ADR 0003](../adr/en/0003-uplink-intent-reliability-and-wifi-horizon-calibration.md)  
**Related Spec:** [Latency & Jitter Compensation Spec](./latency-compensation-spec.md)

---

## 1. Context & Observations

During physical multi-machine LAN Wi-Fi playtests (isolated from the external internet), two critical netcode breakdown scenarios were observed under radio interference and wireless packet loss:

1. **Phantom / Ghost Walking Through Obstacles ("The Overwatch Effect"):**
   * When packet loss or jitter spikes occur while an input key is pressed, the client continues integrating local prediction (`pos = pos + dir * speed * dt`) or extrapolation (`pos = pos + vx * dt`) uninterrupted every frame.
   * Because collision filtering and map boundaries are enforced authoritatively by the Rust server (`loci2d`), the client lacks local geometry knowledge.
   * Without a **Prediction Horizon Cap**, if no server snapshots arrive for 500ms–2000ms, the local player's avatar walks through walls and sails off the map edges.

2. **Frequent Inactivity Timeouts & The Zombie Client State:**
   * **Heartbeat Asymmetry:** The client SDK originally emitted heartbeat pings only once every **2.0 seconds**, whereas the server instance enforces a strict **10-second inactivity threshold** (`client_timeout_secs = 10`). Under bursty Wi-Fi conditions, dropping 4–5 consecutive UDP packets reliably triggers an eviction on the server.
   * **The Zombie State:** Once the server evicts a session for timeout, it ceases broadcasting `WorldState` packets to that IP/port. The client receives no despawn notification and retains `my_entity_id` in memory. The client continues pinging every 2s, but the server drops non-join intents from unrecognized endpoints silently (`apply_intent: None => Ok(None)`). The client enters a permanent zombie loop, never realizing it was disconnected and never re-joining.

---

## 2. Design Goals & Reusability Principles

To preserve 100% engine-agnostic reusability across any future LÖVE2D game built on `loci2d`:

1. **Prediction Horizon (Timeout Cap):** Bound client-side prediction to a configurable horizon (default `500ms`, calibrated per ADR 0003 for Wi-Fi contention stalls). If no authoritative snapshot arrives within this window, motion gracefully decays to zero.
2. **Accelerated Heartbeat Cadence:** Increase heartbeat frequency to `300ms–400ms` (~2.5–3.3 Hz). A client must withstand over 25 consecutive dropped packets before risking server timeout.
3. **Client-Side Connection Watchdog:** If the client receives zero packets from the server for a threshold duration (default `4.0s`), declare connection loss, transition session state, and initiate automated re-join with exponential backoff.
4. **Lifecycle Callbacks:** Expose optional event hooks (`on_connection_lost(reason)`, `on_reconnected(entity_id)`) so games can display standard UX indicators ("Reconnecting...", warning toasts) without SDK coupling.
5. **Synthetic Network Simulator (DX):** Built-in optional artificial latency and packet loss injection in `loci.netcode` (applied symmetrically to inbound and outbound UDP packets per ADR 0003) for local testing without needing OS-level traffic shaping tools (`tc/netem`, Clumsy).

---

## 3. Architecture & State Machine

```
              [ Connected & Healthy ]
                         │
        (No packets received for > 500ms)
                         │
                         ▼
             [ Prediction Starvation ]
             - Freeze / zero-out predicted velocity
             - Stop avatar at last confirmed position
             - Prevent ghost walking through walls
                         │
        (No packets received for > 4000ms)
                         │
                         ▼
             [ Connection Watchdog Lost ]
             - Fire on_connection_lost("timeout")
             - Reset my_entity_id = nil
             - Clear snapshot buffer
                         │
                         ▼
             [ Automated Reconnection ]
             - Resend JoinIntent with backoff
             - Await new WorldState / Player Entity
                         │
            (Server responds with entity)
                         │
                         ▼
                 [ Reconnected ]
             - Restore my_entity_id
             - Fire on_reconnected(my_entity_id)
```

---

## 4. Technical Specifications

### 4.1. Prediction Horizon & Starvation Decoupling

* **Configuration Parameter:** `loci.netcode.prediction_timeout` (default: `0.500` seconds / 500ms).
* **Tracking Variable:** `loci._last_state_received_time = socket.gettime()`, updated on every incoming `WorldState` packet.
* **Logic in `loci.update(dt)`:**
  $$\Delta t_{\text{silence}} = \text{now} - \text{loci.\_last\_state\_received\_time}$$
  * If $\Delta t_{\text{silence}} \le \text{prediction\_timeout}$: Apply normal prediction (or user prediction handler), or mirror server velocity while `_active_move_cleared_by_timeout` awaits post-reconnect consumer `send_move`.
  * If $\Delta t_{\text{silence}} > \text{prediction\_timeout}$:
    * Force `entity.vx = 0`, `entity.vy = 0`.
    * Do not integrate positional displacement $\Delta x, \Delta y$.
    * Freeze avatar visually at its current coordinates.
    * Once a new `WorldState` arrives, smooth reconciliation handles any micro-gap.

### 4.2. Accelerated Heartbeat Cadence

* **Configuration Parameter:** `loci.netcode.heartbeat_interval` (default: `0.400` seconds / 400ms).
* **Behavior:**
  * While connected (`my_entity_id ~= nil`), send `{ ping = {} }` every `heartbeat_interval`.
  * At 400ms interval, 25 packets must be dropped consecutively to trigger the server's 10-second timeout.

### 4.3. Uplink `MoveIntent` Keepalive, CC Gating & Stop Redundancy (ADR 0003)

* **Configuration Parameters:**
  * `loci.netcode.intent_keepalive_interval` (default: `0.100` seconds / 100ms).
  * `loci.netcode.stop_redundancy_count` (default: `3` total stop packets).
* **Behavior:**
  * **Active Movement Keepalive:** While `_active_move_dx ~= 0 or _active_move_dy ~= 0`, `poll_network` periodically retransmits the active `MoveIntent` every `intent_keepalive_interval` so dropped initial UDP packets self-heal within ~100ms.
  * **Crowd-Control (CC) Awareness:** Periodic retransmissions pause while `prediction.is_incapacitated(ent, tick)` is true (`is_dead`, `stunned_until`, `paralyzed_until`) to avoid `on_intent_rejected` spam, setting `_was_incapacitated_with_move = true`. Immediately upon CC expiry, a single recovery `MoveIntent` flushes automatically.
  * **Stop Redundancy Tail:** Transitioning from movement to `(0, 0)` on an active UDP socket emits up to `stop_redundancy_count - 1` extra `(0, 0)` datagrams spaced `>= 30ms` apart (bounded to `0.5s` elapsed since stop transition) so lost stop packets do not leave the server gliding.

### 4.4. Client Connection Watchdog & Auto-Reconnect

* **Configuration Parameter:** `loci.netcode.connection_timeout` (default: `4.0` seconds).
* **Configuration Parameter:** `loci.netcode.auto_reconnect` (default: `true`).
* **Behavior:**
  * If `now - loci._last_packet_received_time > loci.netcode.connection_timeout` (or `connection_timeout`) while previously connected:
    1. Mark connection as lost and set `_active_move_cleared_by_timeout = true`.
    2. Notify application: `loci.on_connection_lost("heartbeat timeout")`.
    3. Clear `loci.my_entity_id = nil`, clear `loci._snapshot_buffer`.
    4. If `auto_reconnect == true`:
       - Trigger re-join sequence: emit `JoinIntent` with `loci._player_name`.
       - Repeat with backoff until accepted or explicitly disconnected.
    5. Upon receiving `WorldState` containing player matching `_player_name`:
       - Restore `loci.my_entity_id = raw_ent.id`.
       - Parse all snapshot entities first so `loci.get_my_entity()` is populated, then notify application: `loci.on_reconnected(loci.my_entity_id)`.

### 4.5. Symmetric Synthetic Latency & Loss Simulator (Developer Experience)

To enable developers to test packet loss and jitter behaviors locally without requiring specialized hardware or third-party packet shapers:

* `loci.netcode.simulate_packet_loss`: Float between `0.0` (0%) and `1.0` (100%). When $> 0$, UDP datagrams are randomly dropped with probability $p$ symmetrically on both inbound (`transport.lua`) and outbound (`protocol.lua`, excluding `disconnect` shutdown packets) paths.
* `loci.netcode.simulate_latency`: Float in seconds (e.g. `0.050` for 50ms). When $> 0$, inbound packets are queued in `_delayed_packet_queue` and outbound packets are queued in `_delayed_outbound_queue` before UDP delivery.

---

## 5. Configuration Surface

```lua
loci.netcode = {
    -- Existing Phase 1 & 2 settings
    prediction_enabled = true,
    interpolation_delay = 0.050,
    reconciliation_threshold = 2.0,
    snap_threshold = 50.0,
    error_decay_rate = 15.0,
    default_move_speed = 3.0,

    -- Resilience, Uplink & Reconnection settings (ADR 0002 & ADR 0003)
    prediction_timeout = 0.500,        -- Max silence before pausing prediction (absorbs Wi-Fi micro-stalls, stops ghosting)
    intent_keepalive_interval = 0.100, -- Periodic MoveIntent retransmission cadence while moving
    stop_redundancy_count = 3,         -- Total stop packets sent on transition to (0, 0)
    heartbeat_interval = 0.400,        -- Fast heartbeat ping cadence (2.5 pings/sec)
    connection_timeout = 4.0,          -- Silence threshold before declaring disconnect
    auto_reconnect = true,             -- Automatically re-join session upon packet loss eviction
    
    -- Diagnostic / synthetic testing settings
    simulate_packet_loss = 0.0,        -- 0.0 to 1.0 (symmetric inbound/outbound random drop)
    simulate_latency = 0.0,            -- Simulated delay in seconds (symmetric inbound/outbound)
}

-- Application Callbacks
loci.on_connection_lost = function(reason) end
loci.on_reconnected = function(entity_id) end
```

---

## 6. Implementation Plan

1. **ADR 0002 Documentation:**
   - Record architectural decision in `docs/adr/en/0002-netcode-packet-loss-resilience-and-auto-reconnect.md` and `docs/adr/pt/0002-resiliencia-a-perda-de-pacotes-e-reconexao-automatica.md`.
2. **Update `loci_client.lua`:**
   - Implement `prediction_timeout` gate in `loci.update(dt)`.
   - Update heartbeat cadence to `0.400s`.
   - Implement watchdog timer and auto-reconnect logic.
   - Implement synthetic network simulator options.
3. **Automated Unit Testing (`test_sdk.lua`):**
   - Add test cases verifying prediction halts when elapsed silence $> 200\text{ms}$.
   - Add test cases verifying connection watchdog fires when elapsed silence $> 4.0\text{s}$.
   - Add test cases verifying re-join intent emission and restoration of `my_entity_id`.
