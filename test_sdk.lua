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

print("All loci_client.lua SDK unit tests passed successfully!")
