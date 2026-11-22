# Loci2D Client SDK - AI Agent Reference

> **Context:** You are an AI assistant helping a developer build a multiplayer 2D game using Love2D and the `loci2d` game engine. 

## Engine Architecture (For the AI)
- `loci2d` is an authoritative Rust server that handles all physics, collisions, and state.
- The developer is using the `loci` (`loci_client.lua`) SDK, which abstracts away all UDP sockets, Protocol Buffers, and network interpolation. **DO NOT generate any `luasocket` or `protobuf` code.**
- The server uses fixed-point math internally, but the SDK automatically converts this. **Always use standard Lua floats** for coordinates (`x`, `y`).
- The SDK automatically manages the player's connection and session heartbeat.

## Public SDK API

### 1. Connection Lifecycle & Session Resume
- `loci.connect(ip, port, player_name, [base_path], [tick_rate], [session_token])`: Connects to the server (and optionally resumes an existing session if `session_token` is provided).
- `loci.resume(ip, port, [player_name], [session_token])`: Reconnects over a new UDP socket using the stored (or provided) `session_token` so the player reclaims their existing entity, team, and score without spawning a clone.
- `loci.get_session_token()` / `loci.set_session_token(token)`: Gets or sets the active session resume token.
- `loci.disconnect(reason)`: Disconnects gracefully and invalidates the current `session_token`.
- `loci.update(dt)`: **MUST** be called every frame inside `love.update(dt)`. It processes all network packets, handles entity interpolation, and runs the automatic reconnection watchdog.

### 2. State Access
- `loci.get_entities()`: Returns a table of all entities currently visible to the client.
- `loci.get_entities_by_blueprint(blueprint_name)`: Filters active entities by blueprint name.
- `loci.get_entities_by_type(entity_type)`: Filters active entities by normalized type (`"player"`, `"npc"`, `"prop"`, `"projectile"`), sorted by `id`.
- `loci.get_projectiles()`: Convenience helper returning all active projectile entities (`entity:is_projectile()`), sorted by `id`.
- `loci.get_my_entity()`: Returns the local player's `Entity` object.
- `loci.get_globals()`: Returns a table of global match properties (e.g., scores, timers).
- `loci.get_entities_in_radius(center_x, center_y, radius)`: Spatial query helper.
- `loci.get_obstacles()`: Returns a list of all active static obstacles (`wall`, `crate`, `trigger`), sorted by `id`.
- `loci.get_obstacle(id)`: Returns a single `Obstacle` by ID, or `nil`.
- `loci.get_obstacles_by_blueprint(blueprint_name)`: Filters active obstacles by blueprint (e.g., `"wall"`, `"crate"`).
- `loci.get_solid_obstacles()`: Returns only solid physical blockers (`obs.is_solid == true`).
- `loci.get_obstacles_in_radius(center_x, center_y, radius)`: Spatial query checking shape overlap within `radius`.

### 3. The `Entity` Object
Entities are NOT simple tables. They have a metatable that automatically casts properties.
- **Transform**: `entity.x`, `entity.y`, `entity.vx`, `entity.vy` (all floats).
- **Metadata**: `entity.id`, `entity.blueprint` (string), `entity.entity_type` (`"player"`, `"npc"`, `"prop"`, or `"projectile"`).
- **Dynamic Properties**: Accessed directly via `entity.prop_name` (e.g., `entity.hp`, `entity.team`). Values are automatically cast to `number` or `boolean`.
- **Methods**: 
  - `entity:is_local_player()` -> bool
  - `entity:is_projectile()` / `entity:is_player()` / `entity:is_npc()` / `entity:is_prop()` -> bool
  - `entity:distance_to(other_entity_or_table)` -> number

### 3b. The `Obstacle` Object
Static obstacles (`wall`, destructible `crate`, `trigger` zone) also use an auto-casting metatable:
- **Geometry & Transform**: `obs.x`, `obs.y`, `obs.shape` (`"aabb"` or `"circle"`), `obs.width`, `obs.height` (for AABB), `obs.radius` (for Circle).
- **Metadata**: `obs.id`, `obs.blueprint`, `obs.is_solid` (bool), `obs.collision_type` (`"solid"`, `"destructible"`, `"trigger"`).
- **Dynamic Properties**: Accessed via `obs.prop_name` or `obs:get(key, default)` (e.g., `obs.hp`, `obs.material`).
- **Methods**:
  - `obs:bounds()` -> `min_x, min_y, max_x, max_y`
  - `obs:contains_point(px, py)` -> bool
  - `obs:intersects_circle(cx, cy, radius)` -> bool
  - `obs:distance_to(other_or_table)` -> number

### 4. Sending Intents (Client -> Server)
- `loci.send_move(dir_x, dir_y)`: Sends a movement intent. The vector does not need to be normalized.
- `loci.send_action(ability_id, dir_x, dir_y)`: Casts an ability aiming in a direction vector.
- `loci.send_action_at_position(ability_id, target_world_x, target_world_y)`: Casts an ability towards a World Space coordinate (automatically calculates direction vector from local player entity).
- `loci.send_action_direction(ability_id, dir_x, dir_y)`: Explicit directional cast alias for `send_action`.

### 5. Event Callbacks (Server -> Client)
The developer must assign functions to these callbacks to react to server events:
- `loci.on_entity_spawned = function(entity)`
- `loci.on_entity_despawned = function(entity_id, last_entity)`: `last_entity` carries the final authoritative `x, y` and metadata for impact VFX/SFX.
- `loci.on_property_changed = function(entity, key, old_val, new_val)`: Ideal for updating UI or VFX.
- `loci.on_obstacle_spawned = function(obstacle)`
- `loci.on_obstacle_destroyed = function(obstacle_id, last_obstacle)`: Ideal for crate destruction VFX/SFX.
- `loci.on_obstacle_property_changed = function(obstacle, key, old_val, new_val)`
- `loci.on_action_cast = function(entity, ability_id, dir_x, dir_y)`: Fired when an entity successfully casts an ability. Trigger particle effects or sounds here.
- `loci.on_match_state_changed = function(state, winner)`: `state` is "running", "paused", or "ended".
- `loci.on_intent_rejected = function(reason)`: Fired if the server denies a client action.
- `loci.on_connection_lost = function(reason)`: Fired when heartbeat timeout detects connection loss.
- `loci.on_reconnected = function(entity_id)`: Fired when the player's session is resumed after a drop or socket change.

## AI Instructions
When asked to implement a game feature:
1. Put all visual/audio logic inside the event callbacks (e.g., play attack sound in `on_action_cast`).
2. Map Love2D inputs (`love.keypressed`, `love.mousepressed`) directly to `loci.send_move` and `loci.send_action`.
3. Read game state directly from `loci.get_entities()` and `loci.get_obstacles()` inside `love.draw` to render the game. Do not maintain a separate list of game objects.

### 6. Network Telemetry & Debugging (ADR / Card Telemetria)
Zero-GC telemetry monitoring for RTT, RFC 3550 Jitter, Packet Loss %, and Tick Frequency.
- `loci.get_ping()` / `loci.get_rtt()` -> number: Current RTT in milliseconds.
- `loci.get_jitter()` -> number: Current RFC 3550 EWMA jitter in milliseconds.
- `loci.get_packet_loss()` -> number: Packet loss percentage (0.0 to 100.0).
- `loci.get_tick_hz()` -> number: Measured server snapshot rate in Hz.
- `loci.get_network_stats()` -> table: All aggregated metrics.
- `loci.toggle_debug_overlay()`: Toggles the on-screen network telemetry HUD.
- `loci.draw_debug_overlay(x, y)` / `loci.draw()`: Renders `[REDE] Ping: 42ms (min: 35 | max: 85) | Jitter: 8.2ms | Loss: 1.2% | Tick: 30.1 Hz`.
- `loci.export_network_stats_csv([filepath])`: Exports telemetry to CSV (`logs/network_stats_<timestamp>.csv`).
- `loci.keypressed(key)`: Handles `F3` (toggle overlay) and `F4` (export CSV).
- `loci.quit()`: Flushes and exports telemetry on game exit.

### 7. Server-side scripting tips
- **Dash ability:** To implement a dash ability that passes through enemies but stops at walls, the server script should use `Loci.Physics.raycast` to find walls and `Loci.Commands.set_collision_filter` to temporarily ignore entities. Always remember to restore the original collision filter!
- **Walls, crates & trigger zones:** Spawn static geometry from `on_init` via `Loci.Commands.spawn_static_obstacle({ blueprint = "crate", position = { x = 10, y = 0 }, width = 4, height = 4, collision_type = "destructible", properties = { hp = 2 } })`. Client prediction automatically resolves against solid obstacles (`obs.is_solid == true`).
- **Physical projectiles:** Spawn projectiles with `Loci.Commands.spawn_entity({ blueprint = "fireball", entity_type = "Projectile", position = pos, velocity = { x = dir_x * 15, y = dir_y * 15 }, radius = 1.0, lifetime_ticks = 30 })`. Projectiles use swept CCD (anti-tunneling), sensor collision (`on_collision` without pushing targets), and notify `on_static_collision(entity_id, obstacle_id, nx, ny)` and `on_boundary_collision(entity_id, nx, ny)` for destruction or ricochet reflection.
