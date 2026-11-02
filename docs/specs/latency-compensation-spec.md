# Technical Specification: Latency & Jitter Compensation in LÖVE2D SDK
**Module:** `loci_client.lua` (`sdk-love2d`)  
**Author:** Antigravity / Loci2D Team  
**Status:** Accepted  
**Compatibility:** `loci2d` v0.6.x+  
**Architecture Record:** [ADR 0001](../adr/en/0001-client-side-prediction-and-snapshot-interpolation.md)

---

## 1. Context & Motivation

During tests on a local wireless network (Wi-Fi), even when disconnected from the external internet, significant **jitter (stuttering and visual hitches)** was observed in character movement and camera tracking.

### Root Cause Analysis:
1. **Lack of Client-Side Prediction (CSP):** The client sends `send_move(dx, dy)` and passively waits for the server to reply with the updated `WorldState` before moving the local player avatar. Consequently, the player feels the cumulative delay of: `Time to next server tick (~33.3ms at 30Hz)` + `Wi-Fi RTT (5–20ms)` + `Wireless radio jitter`.
2. **Camera-Player Coupling:** In game clients (e.g. `loci-arena`), the camera is directly anchored to `my_entity.x` and `my_entity.y`. Any packet delay instantly freezes not just the character, but the entire rendered scene.
3. **Unstable Extrapolation for Remote Entities:** The current SDK attempts to extrapolate future positions using `server_x + vx * dt`. Under Wi-Fi packet timing variance or whenever another player stops or suddenly changes direction, this dead reckoning overshoots and triggers harsh visual snapping/rubberbanding.

---

## 2. Reusability Principles (Game-Agnostic Design)

### Core Question: *Will placing this inside the SDK remain 100% reusable for future games?*
**Yes, provided the architecture maintains strict separation of concerns:**

| Component | Reusability Level | Ensuring 100% Game Agnosticism |
| :--- | :--- | :--- |
| **Snapshot Interpolation Buffer (Remote Entities)** | **100% Generic** | Any 2D game built on `loci2d` receives `(x, y)` and `(vx, vy)`. Interpolating remote entities in the past with a fixed delay does not depend on any gameplay logic. |
| **Input Reconciliation Pipeline** | **100% Generic** | Tracking persistent input direction, comparing predicted coordinates against server snapshots, and smoothing positional errors via exponential decay is standard netcode mathematics. |
| **Avatar Physics/Movement Prediction** | **Extensible (Default + Hook)** | The SDK provides a default kinematic model (`x = x + dir_x * speed_sec * dt`) that queries dynamic entity speed properties (`"move_speed"` or `"speed"`). For games requiring custom physics (e.g., inertia, custom acceleration, or client-side wall collision anticipation), the SDK exposes a pluggable callback `loci.set_prediction_handler(fn)`. |

---

## 3. System Architecture

```
[ Keyboard / Virtual Joystick Input ]
             │
             ├──> [ loci.send_move ] ──> Sends packet to server (on direction change)
             │                           Caches _active_move_dx, _active_move_dy internally
             │
             └──> [ Client Prediction in update(dt) ]
                        │
                        ▼ (Applies IMMEDIATE displacement in local frame)
                 my_entity.x, my_entity.y
                        │
[ Network: Received WorldState ]
             │
             ├──> If Local Avatar  ──> [ Reconciler with Error Smoothing ]
             │                         (Smoothly absorbs discrepancies via exponential decay)
             │
             └──> If Remote Entity ──> [ Snapshot Ring Buffer ]
                                              │
                                              ▼ (Interpolation at t - delay)
                                       Entities rendered smoothly without jitter
```

---

## 4. Component Details

### 4.1. Snapshot Interpolation (For Remote Entities)

For entities other than the local player, rendering should always look slightly into the past (where state has already been confirmed by the server), eliminating the need to guess future positions.

* **Snapshot Ring Buffer:**
  * The SDK maintains a circular buffer of the last $N$ received snapshots (e.g., 6 to 10 snapshots).
  * Each snapshot stores: `server_tick`, `client_receive_time`, and an entity position map `{ [id] = { x, y, vx, vy } }`.
* **Render Time:**
  $$\text{render\_time} = \text{current\_time} - \text{interpolation\_delay}$$
  * For **LAN Wi-Fi**, a safe, conservative default is **`50ms` to `66ms`** (roughly 1.5 to 2 ticks at 30 Hz).
  * The SDK locates the two surrounding snapshots $S_1$ and $S_2$ such that $S_1.\text{time} \le \text{render\_time} \le S_2.\text{time}$, calculating interpolation factor $t \in [0, 1]$:
    $$\text{pos} = S_1.\text{pos} + (S_2.\text{pos} - S_1.\text{pos}) \times t$$
* **Key Benefit:** Remote player movement remains completely smooth even if Wi-Fi packets arrive in bursts or with minor radio delays.

---

### 4.2. Client-Side Prediction (For Local Player)

* **Persistent Active Input Tracking:**
  * Games typically invoke `send_move(dx, dy)` only when the directional vector changes (e.g., pressing or releasing keys).
  * The SDK internally stores `_active_move_dx` and `_active_move_dy` whenever `send_move` is called.
  * In `loci.update(dt)`, displacement is applied continuously every frame as long as an active input vector is held.
* **Speed Unit Scaling & Property Resolution:**
  * In `loci2d`, speed properties (e.g. `"move_speed" = 3.0`) represent **units per tick**.
  * To calculate displacement per second in Love2D's `dt` (seconds):
    $$\text{speed\_units\_per\_tick} = \text{entity:get("move\_speed")} \lor \text{entity:get("speed")} \lor \text{loci.netcode.default\_move\_speed}$$
    $$\text{speed\_sec} = \text{speed\_units\_per\_tick} \times \text{loci.server\_tick\_rate}$$
    $$\Delta x = \text{dir\_x} \times \text{speed\_sec} \times dt$$
* **Status Effect & Death Gates:**
  * The SDK checks status properties on `my_entity`:
    * If `entity:get("is_dead") == "true"` or `entity:get("is_dead") == true`: prediction is suspended.
    * If `current_tick < entity:get("stunned_until", 0)` or `current_tick < entity:get("paralyzed_until", 0)`: prediction is suspended.
  * Ensures zero divergence when the player is incapacitated or under crowd control.

---

### 4.3. Smooth Error Reconciliation

When the server responds with an authoritative snapshot:
1. Compare the authoritative server position against the client's predicted position.
2. If a discrepancy exists (e.g., colliding with a server-side obstacle, or float delta):
   * **Negligible Error ($< 2$ pixels):** Ignored to avoid micro-tremors from floating-point roundoff.
   * **Moderate Error ($2$ to $50$ pixels):** Do not snap/teleport. Compute an error offset vector:
     $$\vec{E} = \text{pos}_{\text{authoritative}} - \text{pos}_{\text{predicted}}$$
     Apply exponential decay to the visual offset during rendering:
     $$\vec{E}(t + dt) = \vec{E}(t) \times e^{-\lambda \cdot dt}$$
     The player continues moving uninterrupted while the correction smoothly blends in.
   * **Critical Error ($> 50$ pixels / Hard Rubberband):** Immediate snap to server position (e.g., hard knockback, stun, or teleport).

---

## 5. Public SDK Configuration & Extensibility

To ensure frictionless reuse across diverse projects, `loci_client.lua` exposes standard configuration defaults and extension hooks:

```lua
-- Netcode Configuration (Optimized defaults for LAN)
loci.netcode = {
    -- Enable / disable client-side prediction
    prediction_enabled = true,
    
    -- Remote entity interpolation delay buffer (in seconds)
    -- 0.050s = 50ms (Ideal for 30Hz LAN Wi-Fi)
    interpolation_delay = 0.050,
    
    -- Threshold in pixels before applying error reconciliation
    reconciliation_threshold = 2.0,
    
    -- Maximum distance error before forcing an immediate snap
    snap_threshold = 50.0,
    
    -- Exponential decay rate for smoothing errors (higher = faster convergence)
    error_decay_rate = 15.0,
    
    -- Fallback movement speed (units per tick) if property missing
    default_move_speed = 3.0,
}

-- Pluggable prediction handler for projects requiring custom physics
-- If nil, the SDK uses the default kinematic model: dir * speed_sec * dt
loci.set_prediction_handler(function(entity, dx, dy, dt)
    -- Example for games with acceleration or friction:
    -- local speed = (entity:get("move_speed") or loci.netcode.default_move_speed) * loci.server_tick_rate
    -- entity.vx = entity.vx + dx * accel * dt
    -- entity.x = entity.x + entity.vx * dt
end)
```

---

## 6. Implementation Roadmap

### **Phase 1: Snapshot Buffer for Remote Entities**
- Implement the circular snapshot buffer in `loci_client.lua`.
- Update `loci.update(dt)` to interpolate remote entities between historical snapshots.
- **Expected Outcome:** Remote player stuttering disappears completely on Wi-Fi.

### **Phase 2: Client-Side Prediction for Local Player**
- Track persistent input direction (`_active_move_dx`, `_active_move_dy`).
- Calculate dynamic speed (`move_speed * server_tick_rate`) and apply frame-accurate displacement.
- Gate prediction by status effect properties (`stunned_until`, `paralyzed_until`, `is_dead`).
- **Expected Outcome:** Immediate, crisp input response for the local avatar and camera.

### **Phase 3: Smooth Error Reconciliation**
- Implement exponential error decay buffer to blend positional corrections seamlessly on obstacle collisions.
