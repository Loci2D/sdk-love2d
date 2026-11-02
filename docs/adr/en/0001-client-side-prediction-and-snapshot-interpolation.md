# ADR 0001: Client-Side Prediction and Snapshot Interpolation for Latency Compensation

## Status
Accepted

## Context
Following [ADR 0020](file:///home/furlan/Documentos/workspace/loci2d/docs/adr/en/0020-client-sdks-decoupling-and-extraction.md) in `loci2d`, the Love2D client SDK was extracted into a dedicated repository (`Loci2D/sdk-love2d`).

When testing multiplayer matches over local wireless networks (Wi-Fi) without external internet, significant visual jitter and sluggish control responsiveness were observed. The root causes were identified as:
1. **Coupled Response to Server WorldState:** The local player avatar moved exclusively upon receiving authoritative `WorldState` snapshots from the server. Even in local Wi-Fi with low average ping (5–15ms), packet timing jitter and server tick delays (33.3ms at 30Hz) created noticeable control latency and intermittent freezing.
2. **Camera Jitter:** In client games like `loci-arena`, the camera is directly anchored to the local player position. Any frame hitch in server packet arrival caused whole-screen stutter.
3. **Dead Reckoning Extrapolation Overshoot:** For remote players, extrapolating positions based on instantaneous velocity caused rubberbanding and snappy corrections whenever entities changed direction or stopped.

## Decision
We decided to implement a dual-layer, game-agnostic latency compensation architecture inside `loci_client.lua`:

### 1. Snapshot Interpolation for Remote Entities
* Maintain a circular buffer of the most recent server snapshots (default 8 snapshots).
* Render remote entities at an interpolated historical timestamp:
  $$\text{render\_time} = \text{current\_time} - \text{interpolation\_delay}$$
* Establish a conservative, fixed default interpolation delay of **50ms** (~1.5 server ticks at 30Hz), which fully absorbs local Wi-Fi radio jitter without requiring complex adaptive heuristics in v1.

### 2. Kinematic Client-Side Prediction for Local Avatar
* Retain the active movement input direction internally across frames, ensuring smooth displacement even when consumer games only emit `send_move()` on input changes.
* Apply immediate displacement each frame in `loci.update(dt)`:
  $$\Delta \text{pos} = \vec{\text{dir}} \times (\text{move\_speed} \times \text{server\_tick\_rate}) \times dt$$
* Dynamically resolve speed from the entity's synced properties (`"move_speed"` with fallback to `"speed"` or configuration default), naturally adapting to server-side skill buffs/debuffs (e.g., slows, dashes).
* Respect server-authoritative crowd-control properties (`"stunned_until"`, `"paralyzed_until"`, `"is_dead"`) by suspending prediction when incapacitated.

### 3. Smooth Positional Reconciliation
* Discrepancies between predicted position and authoritative server snapshots are absorbed using exponential error decay ($E_{t+dt} = E_t \cdot e^{-\lambda dt}$) rather than visual snaps, with a hard snap threshold (default 50px) reserved for teleportation or severe collisions.

### 4. Pluggable Extensibility
* Expose `loci.netcode` configuration table for game-level tuning.
* Provide `loci.set_prediction_handler(fn)` to allow future games with non-linear physics or client-side collision anticipation to supply custom prediction logic.

## Consequences
- **Positive:** Perceived local control latency drops to $0\text{ms}$; camera and avatar movement become completely smooth.
- **Positive:** Remote player jitter on local Wi-Fi is eliminated via past-state interpolation.
- **Positive:** 100% reusable across any future game built on `sdk-love2d`.
- **Positive:** Maintains server authority; the server remains the single source of truth for all game rules and physical positions.
- **Negative:** Adds a small memory footprint for snapshot circular buffers.
- **Negative:** Remote players are displayed with an imperceptible 50ms render delay.
