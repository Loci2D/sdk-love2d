-- Test suite for loci_client.lua (Love2D Client SDK)
-- Validates Entity metatable, auto-casting, helpers, and packet handling.

package.path = package.path .. ";./?.lua;./lib/?.lua"
package.cpath = package.cpath .. ";./lib/?.so;./lib/?.dylib;./lib/?.dll;./?.so;./?.dylib;./?.dll;/usr/local/lib/lua/5.1/?.so"

local loci = require("loci_client")

local action_cast_called = false
local match_state_called = false
local intent_rejected_called = false

loci.on_action_cast = function(ent, ability, dx, dy)
    action_cast_called = true
    assert(ent.id == 10, "entity id should be 10")
    assert(ability == 2, "ability should be 2")
    assert(math.abs(dx - 1.0) < 0.001, "dx should be ~1.0")
end

loci.on_match_state_changed = function(state, winner)
    match_state_called = true
    assert(state == "ended", "state should be ended")
    assert(winner == "Team Blue", "winner should be Team Blue")
end

loci.on_intent_rejected = function(reason)
    intent_rejected_called = true
    assert(reason == "Stunned", "rejection reason mismatch")
end

-- Simulate WorldState
local mock_state = {
    tick = 1,
    timestamp = 1000,
    globals = {
        { key = "round", value = "3" },
        { key = "is_overtime", value = "true" },
        { key = "mode", value = "3v3_arena" }
    },
    match_state = 2,
    match_winner = "Team Blue",
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = 65536 * 5, y_bits = 65536 * 10 },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {
                { key = "hp", value = "100" },
                { key = "is_alive", value = "true" },
                { key = "role", value = "tank" },
                { key = "team", value = "1" }
            }
        },
        {
            id = 11,
            name = "Enemy_Minion",
            position = { x_bits = 65536 * 8, y_bits = 65536 * 14 },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {
                { key = "hp", value = "30" },
                { key = "team", value = "2" }
            }
        }
    },
    actions = {
        {
            entity_id = 10,
            ability_id = 2,
            target_direction = { x_bits = 65536, y_bits = 0 }
        }
    }
}

loci._player_name = "Player_Hero"
loci._handle_world_state(mock_state)

assert(action_cast_called, "on_action_cast must be triggered")
assert(match_state_called, "on_match_state_changed must be triggered")

local p10 = loci.entities[10]
assert(p10 ~= nil, "entity 10 should exist")
assert(p10.x == 5, "p10.x should be 5")
assert(p10.y == 10, "p10.y should be 10")
assert(p10.hp == 100, "p10.hp should be cast to number 100")
assert(type(p10.hp) == "number", "p10.hp should be number type")
assert(p10.team == 1, "p10.team should be cast to number 1")
assert(p10.is_alive == true, "p10.is_alive should be boolean true")
assert(p10.role == "tank", "p10.role should be string tank")
assert(p10:is_local_player() == true, "p10:is_local_player() must return true")
assert(p10:get("hp") == 100, "p10:get('hp') should return 100")
assert(p10:get("mana", 50) == 50, "p10:get with fallback should return default value")

local dist = p10:distance_to(loci.entities[11])
assert(math.abs(dist - 5.0) < 0.001, "distance (3,4,5 triangle) should be 5.0")

local in_radius = loci.get_entities_in_radius(5, 10, 6)
assert(#in_radius == 2, "both entities should be in radius 6")

local in_radius_small = loci.get_entities_in_radius(5, 10, 2)
assert(#in_radius_small == 1, "only p10 should be in radius 2")

local globals = loci.get_globals()
assert(globals["round"] == 3, "globals.round should be number 3")
assert(globals["is_overtime"] == true, "globals.is_overtime should be boolean true")
assert(globals["mode"] == "3v3_arena", "globals.mode should be string")

-- Test server response rejection feedback
loci._handle_response({ status = "rejected: Stunned" })
assert(intent_rejected_called, "on_intent_rejected must be triggered")

-- Test version metadata
assert(loci.VERSION == "0.6.2", "loci.VERSION should be 0.6.2")
assert(loci.COMPATIBLE_ENGINE_VERSION == "0.6.x", "loci.COMPATIBLE_ENGINE_VERSION should be 0.6.x")

-- Test netcode configuration defaults (ADR 0001)
assert(loci.netcode ~= nil, "loci.netcode table must exist")
assert(loci.netcode.prediction_enabled == true, "prediction_enabled default must be true")
assert(loci.netcode.interpolation_delay == 0.050, "interpolation_delay default must be 50ms")
assert(loci.netcode.snap_threshold == 50.0, "snap_threshold default must be 50.0")
assert(loci.netcode.reconciliation_threshold == 2.0, "reconciliation_threshold default must be 2.0")
assert(type(loci.get_snapshot_buffer()) == "table", "get_snapshot_buffer must return a table")

-- Test action helpers & position-to-direction conversion
local last_sent_intent = nil
loci._send_intent = function(intent)
    last_sent_intent = intent
end

-- 1. send_action with numeric direction
loci.send_action(1, 10, 0)
assert(last_sent_intent and last_sent_intent.action, "action intent must be sent")
assert(last_sent_intent.action.ability_id == 1, "ability_id must be 1")
assert(last_sent_intent.action.target_direction.x_bits == 65536, "normalized dx should be 1.0 (65536 bits)")
assert(last_sent_intent.action.target_direction.y_bits == 0, "normalized dy should be 0")

-- 2. send_action with string coercion
loci.send_action("2", "0", "-5")
assert(last_sent_intent.action.ability_id == 2, "ability_id string must be accepted")
assert(last_sent_intent.action.target_direction.x_bits == 0, "dx should be 0")
assert(last_sent_intent.action.target_direction.y_bits == -65536, "dy should be -1.0 (-65536 bits)")

-- 3. send_action_at_position (p10 is at x=5, y=10; target is at x=15, y=10 -> delta is (+10, 0))
loci.send_action_at_position(3, 15, 10)
assert(last_sent_intent.action.ability_id == 3, "ability_id must be 3")
assert(last_sent_intent.action.target_direction.x_bits == 65536, "aiming (+10, 0) should normalize to (+1, 0)")
assert(last_sent_intent.action.target_direction.y_bits == 0, "y_bits should be 0")

-- 4. send_action_direction alias
loci.send_action_direction(4, 0, 1)
assert(last_sent_intent.action.ability_id == 4, "ability_id must be 4")
assert(last_sent_intent.action.target_direction.y_bits == 65536, "dy should be 1.0 (65536 bits)")

-- ============================================================================
-- Phase 1 Unit Tests: Snapshot Buffer & Remote Entity Interpolation
-- ============================================================================

-- Reset snapshot buffer
loci._snapshot_buffer = {}

-- Snapshot 1: Enemy Minion (entity 11) is at (10, 20) at t = 1.000
local state_snap1 = {
    tick = 10,
    _receive_time = 1.000,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = 65536 * 5, y_bits = 65536 * 10 },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        },
        {
            id = 11,
            name = "Enemy_Minion",
            position = { x_bits = 65536 * 10, y_bits = 65536 * 20 },
            velocity = { x_bits = 65536 * 2, y_bits = 65536 * 2 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_snap1)

-- Snapshot 2: Enemy Minion moved to (30, 40) at t = 1.100 (100ms later)
local state_snap2 = {
    tick = 13,
    _receive_time = 1.100,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = 65536 * 5, y_bits = 65536 * 10 },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        },
        {
            id = 11,
            name = "Enemy_Minion",
            position = { x_bits = 65536 * 30, y_bits = 65536 * 40 },
            velocity = { x_bits = 65536 * 2, y_bits = 65536 * 2 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_snap2)

assert(#loci.get_snapshot_buffer() == 2, "snapshot buffer should hold 2 snapshots")

-- Test midpoint interpolation:
-- If mock_time = 1.100 and interpolation_delay = 0.050 (50ms):
-- render_time = 1.100 - 0.050 = 1.050 (exactly midpoint between 1.000 and 1.100, alpha = 0.5)
loci.netcode.interpolation_delay = 0.050
loci._mock_time = 1.100
loci.update(0.016)

local minion = loci.entities[11]
assert(minion ~= nil, "minion should exist in loci.entities")
assert(math.abs(minion.x - 20.0) < 0.001, "remote entity x should interpolate to 20.0 at alpha=0.5, got " .. tostring(minion.x))
assert(math.abs(minion.y - 30.0) < 0.001, "remote entity y should interpolate to 30.0 at alpha=0.5, got " .. tostring(minion.y))

-- Test 25% interpolation (alpha = 0.25):
-- render_time = 1.025 -> x = 10 + 20 * 0.25 = 15.0; y = 20 + 20 * 0.25 = 25.0
loci._mock_time = 1.075
loci.update(0.016)
assert(math.abs(minion.x - 15.0) < 0.001, "remote entity x should interpolate to 15.0 at alpha=0.25, got " .. tostring(minion.x))
assert(math.abs(minion.y - 25.0) < 0.001, "remote entity y should interpolate to 25.0 at alpha=0.25, got " .. tostring(minion.y))

-- Test teleport/snap behavior when distance exceeds snap_threshold (>50px)
local state_snap3_teleport = {
    tick = 16,
    _receive_time = 1.200,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = 65536 * 5, y_bits = 65536 * 10 },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        },
        {
            id = 11,
            name = "Enemy_Minion",
            position = { x_bits = 65536 * 200, y_bits = 65536 * 200 }, -- Teleported 170+ units away
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_snap3_teleport)

-- Render between snap2 (30, 40 at t=1.100) and snap3 (200, 200 at t=1.200)
-- At alpha = 0.6 (render_time = 1.160), since dist > 50, it snaps directly to (200, 200) rather than sliding
loci._mock_time = 1.210 -- render_time = 1.160 (alpha = 0.60)
loci.update(0.016)
assert(minion.x == 200, "teleported entity should snap to 200 on alpha >= 0.5 without sliding, got " .. tostring(minion.x))
assert(minion.y == 200, "teleported entity should snap to 200 on alpha >= 0.5 without sliding, got " .. tostring(minion.y))

-- Reset mock time
loci._mock_time = nil

-- ============================================================================
-- Phase 2 Unit Tests: Client-Side Prediction for Local Player Avatar
-- ============================================================================

local hero = loci.entities[10]
assert(hero ~= nil, "local player entity (10) must exist")
assert(hero:is_local_player() == true, "hero must be identified as local player")

-- Reset hero position to (100, 100)
hero.x = 100.0
hero.y = 100.0
hero.server_x = 100.0
hero.server_y = 100.0
hero._error_x = 0
hero._error_y = 0
loci.server_tick_rate = 30.0
local socket = require("socket")
loci._last_state_received_time = socket.gettime()

-- 1. Test immediate velocity update on send_move
loci.send_move(1, 0)
assert(loci._active_move_dx == 1, "active_move_dx must be 1")
assert(loci._active_move_dy == 0, "active_move_dy must be 0")
assert(hero.vx == 3.0, "hero.vx should immediately update to default_move_speed 3.0, got " .. tostring(hero.vx))
assert(hero.vy == 0, "hero.vy should be 0")

-- 2. Test continuous prediction displacement in update(dt)
-- Speed: move_speed (3.0) * tick_rate (30) = 90 pixels/sec
-- For dt = 0.100s, displacement should be 9.0 pixels: x = 100 + 9 = 109.0
loci.update(0.100)
assert(math.abs(hero.x - 109.0) < 0.001, "hero.x should advance to 109.0, got " .. tostring(hero.x))
assert(hero.y == 100.0, "hero.y should remain at 100.0")

-- Advance again for another 0.100s: x = 109 + 9 = 118.0
loci.update(0.100)
assert(math.abs(hero.x - 118.0) < 0.001, "hero.x should advance to 118.0, got " .. tostring(hero.x))

-- 3. Test stop movement on send_move(0, 0)
loci.send_move(0, 0)
assert(hero.vx == 0, "hero.vx should be 0 on stop")
assert(hero.vy == 0, "hero.vy should be 0 on stop")
loci.update(0.100)
assert(math.abs(hero.x - 118.0) < 0.001, "hero.x should remain unchanged after stopping")

-- 4. Test dynamic move_speed adaptation
hero.properties["move_speed"] = 5.0
loci.send_move(0, 1) -- moving down
assert(hero.vy == 5.0, "hero.vy should adapt to move_speed 5.0, got " .. tostring(hero.vy))
-- Speed: 5.0 * 30 = 150 px/s -> for dt = 0.1s: dy = 15.0 px -> y = 100 + 15 = 115.0
loci.update(0.100)
assert(math.abs(hero.y - 115.0) < 0.001, "hero.y should advance to 115.0 with speed 5.0, got " .. tostring(hero.y))
loci.send_move(0, 0)

-- 5. Test status effect crowd control gate (paralyzed / stunned / dead)
hero.properties["is_dead"] = "true"
loci.send_move(1, 0)
loci.update(0.100)
assert(math.abs(hero.x - 118.0) < 0.001, "dead hero must not advance via prediction")
hero.properties["is_dead"] = "false"

loci._last_state_tick = 50
hero.properties["stunned_until"] = "100"
loci.send_move(1, 0)
loci.update(0.100)
assert(math.abs(hero.x - 118.0) < 0.001, "stunned hero must not advance via prediction")
hero.properties["stunned_until"] = "0"
loci.send_move(0, 0)

-- 6. Test Authoritative Reconciliation:
-- Hero is at x = 118.0, y = 115.0
-- Server sends snapshot where hero is at (118.5, 115.0) -> delta = 0.5px (< reconciliation_threshold 2.0px)
local state_reconcile_small = {
    tick = 55,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = math.floor(118.5 * 65536), y_bits = math.floor(115.0 * 65536) },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_reconcile_small)
assert(math.abs(hero.x - 118.0) < 0.001, "small error (<2px) should not jitter local position")
assert(hero._error_x == 0, "_error_x should be 0 on negligible error")

-- Server sends snapshot with moderate divergence: server says (125.0, 115.0) -> delta = 7.0px (>2px, <50px)
local state_reconcile_moderate = {
    tick = 56,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = math.floor(125.0 * 65536), y_bits = math.floor(115.0 * 65536) },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_reconcile_moderate)
assert(math.abs(hero._error_x - 7.0) < 0.01, "_error_x should record moderate delta for smoothing, got " .. tostring(hero._error_x))

-- Advance update(dt) to let error decay exponentially towards 125.0
loci.update(0.100)
assert(hero.x > 118.0 and hero.x < 125.0, "hero.x should smoothly decay towards server position, current: " .. tostring(hero.x))
-- After several frames, error decay converges completely
for _ = 1, 30 do
    loci.update(0.016)
end
assert(math.abs(hero.x - 125.0) < 0.05, "hero.x should converge to 125.0 after decay, got " .. tostring(hero.x))
assert(hero._error_x == 0, "_error_x should clear once decayed")

-- Server sends critical rubberband/teleport (>50px, e.g. x = 300.0)
local state_reconcile_snap = {
    tick = 57,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = math.floor(300.0 * 65536), y_bits = math.floor(115.0 * 65536) },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_reconcile_snap)
assert(math.abs(hero.x - 300.0) < 0.001, "hero.x should hard snap to 300.0 on discrepancy > 50px")

-- 7. Test custom prediction handler hook
local custom_handler_called = false
loci.set_prediction_handler(function(ent, dx, dy, dt)
    custom_handler_called = true
    ent.x = ent.x + 99.0 * dt
end)
loci.send_move(1, 0)
loci.update(0.100)
assert(custom_handler_called == true, "custom prediction handler must be called when set")
assert(math.abs(hero.x - 309.9) < 0.001, "custom handler displacement should be applied")
loci.set_prediction_handler(nil)
loci.send_move(0, 0)

-- ============================================================================
-- ADR 0002 Unit Tests: Netcode Resilience, Prediction Horizon & Reconnection
-- ============================================================================

-- 1. Test Prediction Horizon Cap (Starvation timeout)
loci.netcode.prediction_timeout = 0.200
hero.x = 500.0
hero.y = 500.0
hero.server_x = 500.0
hero.server_y = 500.0
hero.vx = 0
hero.vy = 0
hero._error_x = 0
hero._error_y = 0

loci._mock_time = 100.000
local state_horizon_base = {
    tick = 100,
    _receive_time = 100.000,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = math.floor(500.0 * 65536), y_bits = math.floor(500.0 * 65536) },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_horizon_base)
assert(loci._last_state_received_time == 100.000, "state receive time should be 100.000")

-- Start moving right at speed = 3.0 * 30 = 90 px/s
loci.send_move(1, 0)

-- At mock_time = 100.100 (100ms silence <= 200ms timeout): prediction active
loci._mock_time = 100.100
loci.update(0.100)
-- 90 px/s * 0.1s = 9px -> x should advance to 509.0
assert(math.abs(hero.x - 509.0) < 0.001, "hero.x should advance to 509.0 within prediction horizon, got " .. tostring(hero.x))

-- At mock_time = 100.250 (250ms silence > 200ms timeout): prediction MUST starve to stop ghost walking
loci._mock_time = 100.250
loci.update(0.150)
assert(hero.vx == 0, "hero.vx should freeze to 0 when prediction is starved, got " .. tostring(hero.vx))
assert(hero.vy == 0, "hero.vy should be 0 when prediction is starved")
assert(math.abs(hero.x - 509.0) < 0.001, "hero.x must NOT advance when prediction is starved, got " .. tostring(hero.x))

-- At mock_time = 100.500 (500ms silence): still starved
loci._mock_time = 100.500
loci.update(0.250)
assert(math.abs(hero.x - 509.0) < 0.001, "hero.x must remain frozen at 509.0 without new server state")

-- Server communication recovers at t = 100.600
local state_horizon_recover = {
    tick = 118,
    _receive_time = 100.600,
    entities = {
        {
            id = 10,
            name = "Player_Hero",
            position = { x_bits = math.floor(509.0 * 65536), y_bits = math.floor(500.0 * 65536) },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_horizon_recover)
assert(loci._last_state_received_time == 100.600, "state receive time updated to 100.600")

-- Move again at t = 100.650 (50ms after recovery): prediction resumes!
loci._mock_time = 100.650
loci.update(0.050)
-- 90 px/s * 0.05s = 4.5px -> x should advance to 513.5
assert(math.abs(hero.x - 513.5) < 0.001, "hero.x should resume prediction upon snapshot recovery, got " .. tostring(hero.x))
loci.send_move(0, 0)

-- 2. Test Connection Watchdog & Automated Reconnection
local connection_lost_event = nil
local reconnected_event = nil
loci.on_connection_lost = function(reason)
    connection_lost_event = reason
end
loci.on_reconnected = function(entity_id)
    reconnected_event = entity_id
end

loci._player_name = "Player_Hero"
loci.my_entity_id = 10
loci._last_packet_received_time = 200.000
loci._last_state_received_time = 200.000
loci.netcode.connection_timeout = 4.0
loci._mock_time = 201.000

-- Track intents sent by client
local sent_intents = {}
loci._send_intent = function(intent)
    table.insert(sent_intents, intent)
end
loci._udp = {
    receive = function(self, max_len)
        return nil, "timeout"
    end,
    close = function(self) end
}

-- Update at 1.0s silence (< 4.0s timeout): no disconnect
loci.update(0.100)
assert(connection_lost_event == nil, "connection must not be lost at 1.0s silence")
assert(loci.my_entity_id == 10, "my_entity_id must still be 10")

-- Fast forward to 204.500 (4.5s silence > 4.0s timeout): Watchdog triggers disconnect & auto-reconnect
loci._mock_time = 204.500
loci.update(0.100)

assert(connection_lost_event == "heartbeat timeout", "on_connection_lost must fire with heartbeat timeout, got: " .. tostring(connection_lost_event))
assert(loci.my_entity_id == nil, "my_entity_id must be cleared on disconnect")
assert(loci._is_reconnecting == true, "client must transition to _is_reconnecting state")
assert(#sent_intents > 0, "client must emit join intent during auto-reconnection")

-- Server accepts reconnection and sends WorldState with player restored (id = 77)
local state_reconnected = {
    tick = 300,
    _receive_time = 205.000,
    entities = {
        {
            id = 77,
            name = "Player_Hero",
            position = { x_bits = math.floor(100.0 * 65536), y_bits = math.floor(100.0 * 65536) },
            velocity = { x_bits = 0, y_bits = 0 },
            properties = {}
        }
    }
}
loci._handle_world_state(state_reconnected)

assert(loci.my_entity_id == 77, "my_entity_id must be restored to 77")
assert(loci._is_reconnecting == false, "_is_reconnecting must be false after reconnection")
assert(reconnected_event == 77, "on_reconnected callback must receive restored entity_id 77")

-- 3. Test Accelerated Heartbeat Cadence (400ms)
assert(loci.netcode.heartbeat_interval == 0.400, "heartbeat_interval must default to 0.400s")
sent_intents = {}
loci._last_heartbeat_time = 300.000
loci._last_packet_received_time = 300.000
loci._mock_time = 300.350 -- 350ms elapsed (< 400ms)
loci.update(0.016)
assert(#sent_intents == 0, "heartbeat must not fire before 400ms elapsed")

loci._mock_time = 300.410 -- 410ms elapsed (> 400ms)
loci.update(0.016)
assert(#sent_intents > 0, "heartbeat must fire once 400ms interval elapses")
assert(loci._last_heartbeat_time == 300.410, "last_heartbeat_time must update to 300.410")

-- 4. Test Synthetic Network Simulator (Latency Delay Queue)
loci._delayed_packet_queue = {}
local dispatched_packets = 0
local orig_dispatch = loci._dispatch_raw_packet
loci._dispatch_raw_packet = function(data)
    dispatched_packets = dispatched_packets + 1
end

loci.netcode.simulate_latency = 0.050 -- 50ms delay
loci._mock_time = 400.000
-- Enqueue packet at t = 400.000
table.insert(loci._delayed_packet_queue, {
    deliver_at = 400.050,
    data = "mock_packet_bytes"
})

-- Update at t = 400.030 (30ms elapsed < 50ms): packet must stay queued
loci._mock_time = 400.030
loci.update(0.016)
assert(dispatched_packets == 0, "packet must not be dispatched before simulated latency expires")
assert(#loci._delayed_packet_queue == 1, "packet must remain in queue")

-- Update at t = 400.060 (60ms elapsed >= 50ms): packet must be delivered
loci._mock_time = 400.060
loci.update(0.016)
assert(dispatched_packets == 1, "packet must be delivered once simulated latency expires")
assert(#loci._delayed_packet_queue == 0, "queue must be drained")

loci._dispatch_raw_packet = orig_dispatch
loci._udp = nil
loci._mock_time = nil

print("All loci_client.lua SDK unit tests passed successfully!")
