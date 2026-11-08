-- ============================================================================
-- Loci2D - Love2D Client SDK Facade (Phase 6.5.3 / ADR 0001 & ADR 0002)
-- High-level abstraction layer over UDP sockets, Protobuf, and Netcode.
-- ============================================================================

local socket = require("socket")

-- Dynamic submodule loading with package prefix preservation
local modname = ... or "loci"
local prefix = (modname:match("^(.-)init$") or (modname .. ".")):gsub("%.+$", ".")

local entity_mod = require(prefix .. "entity")
local schema_mod = require(prefix .. "network.schema")
local protocol_mod = require(prefix .. "network.protocol")
local transport_mod = require(prefix .. "network.transport")
local buffer_mod = require(prefix .. "netcode.buffer")
local interp_mod = require(prefix .. "netcode.interpolation")
local pred_mod = require(prefix .. "netcode.prediction")
local recon_mod = require(prefix .. "netcode.reconciler")
local stats_mod = require(prefix .. "telemetry.stats")
local overlay_mod = require(prefix .. "telemetry.overlay")
local exporter_mod = require(prefix .. "telemetry.exporter")

local loci = {
    -- Metadata
    VERSION = "0.6.2",
    COMPATIBLE_ENGINE_VERSION = "0.6.x",
    SCHEMA_VERSION = 1,
    entities = {},
    globals = {},
    my_entity_id = nil,
    match_state = "running",
    match_winner = "",
    server_tick_rate = tonumber(os.getenv and (os.getenv("LOCI_TICK_RATE") or os.getenv("TICK_RATE"))) or 30.0,

    -- Netcode & Latency Compensation Configuration (ADR 0001 & ADR 0002)
    netcode = {
        prediction_enabled = true,
        interpolation_delay = 0.050,      -- 50ms buffer (safe for 30Hz LAN Wi-Fi)
        reconciliation_threshold = 2.0,    -- 2px tolerance
        snap_threshold = 50.0,             -- 50px max error before hard snap
        error_decay_rate = 15.0,           -- Exponential error smoothing
        default_move_speed = 3.0,          -- Default units/tick

        -- Resilience & Reconnection (ADR 0002)
        prediction_timeout = 0.200,       -- 200ms max silence before pausing prediction (stops ghosting)
        heartbeat_interval = 0.400,       -- 400ms heartbeat cadence (~2.5 pings/sec)
        connection_timeout = 4.0,         -- 4.0s silence threshold before declaring disconnect
        auto_reconnect = true,            -- Automatically re-join session upon packet loss eviction
        auto_export_csv_on_quit = false,

        -- Diagnostic & synthetic testing
        simulate_packet_loss = 0.0,       -- 0.0 to 1.0 (e.g. 0.15 = 15% random drop)
        simulate_latency = 0.0,           -- Simulated delay in seconds (e.g. 0.050 = 50ms)
    },

    -- Network Telemetry (PR #2)
    show_debug_overlay = false,
    network_stats = stats_mod and stats_mod.new({ capacity = 120 }) or nil,

    -- Callbacks
    on_entity_spawned = function(entity) end,
    on_entity_despawned = function(entity_id) end,
    on_property_changed = function(entity, key, old_val, new_val) end,
    on_match_state_changed = function(state, winner) end,
    on_action_cast = function(entity, ability_id, dir_x, dir_y) end,
    on_intent_rejected = function(reason) end,
    on_connection_lost = function(reason) end,
    on_reconnected = function(entity_id) end,

    -- Internal
    _udp = nil,
    _schema_loaded = false,
    _sequence_id = 0,
    _last_heartbeat_time = 0,
    _last_join_attempt_time = 0,
    _last_state_tick = nil,
    _last_state_timestamp = nil,
    _last_state_received_time = nil,
    _last_packet_received_time = nil,
    _is_reconnecting = false,
    _delayed_packet_queue = {},
    _player_name = nil,
    _base_path = "lib/",
    _entities_list_cache = nil,
    _snapshot_buffer = {},
    _max_snapshot_history = 20,
    _prediction_handler = nil,
    _active_move_dx = 0,
    _active_move_dy = 0,
    _inflight_intents = {},
}

-- Bind context so Entity metatable can inspect loci state
entity_mod.bind_context(loci)

function loci.get_server_tick_rate()
    return loci.server_tick_rate or 30.0
end

function loci.set_server_tick_rate(rate)
    local r = tonumber(rate)
    if r and r > 0 then
        loci.server_tick_rate = r
    end
end

function loci.set_prediction_handler(fn)
    loci._prediction_handler = fn
end

function loci.get_snapshot_buffer()
    return loci._snapshot_buffer
end

function loci.connect(host, port, player_name, base_path, tick_rate)
    loci._snapshot_buffer = {}
    loci._active_move_dx = 0
    loci._active_move_dy = 0
    loci._last_state_received_time = nil
    loci._last_packet_received_time = nil
    loci._is_reconnecting = false
    loci._delayed_packet_queue = {}
    loci._last_heartbeat_time = 0
    loci._last_join_attempt_time = 0
    loci._inflight_intents = {}
    if base_path then
        loci._base_path = base_path
    end
    if tick_rate and tonumber(tick_rate) and tonumber(tick_rate) > 0 then
        loci.server_tick_rate = tonumber(tick_rate)
    end

    loci._udp = transport_mod.create_udp(host, port)
    loci._player_name = player_name

    local schema_loaded, _, _ = schema_mod.load(loci._base_path)
    loci._schema_loaded = schema_loaded

    if schema_loaded then
        loci._send_intent({ join = { player_name = player_name, schema_version = loci.SCHEMA_VERSION } })
        return true
    else
        print("[Error] Could not load game_packets schema definition. Aborting network.")
        if loci._udp then
            transport_mod.close_udp(loci._udp)
            loci._udp = nil
        end
        return false
    end
end

function loci.disconnect(reason)
    loci._snapshot_buffer = {}
    loci._active_move_dx = 0
    loci._active_move_dy = 0
    loci._last_state_received_time = nil
    loci._last_packet_received_time = nil
    loci._is_reconnecting = false
    loci._delayed_packet_queue = {}
    loci._inflight_intents = {}
    if loci._udp then
        loci._send_intent({ disconnect = { reason = reason or "client closing" } })
        transport_mod.close_udp(loci._udp)
        loci._udp = nil
    end
end

function loci._send_intent(intent_table)
    protocol_mod.send_intent(loci, schema_mod, intent_table)
end

function loci.send_move(dir_x, dir_y)
    local dx = tonumber(dir_x) or 0
    local dy = tonumber(dir_y) or 0
    loci._active_move_dx = dx
    loci._active_move_dy = dy

    -- Immediate local velocity update for client prediction (Phase 2 - ADR 0001)
    if loci.netcode and loci.netcode.prediction_enabled and loci.my_entity_id then
        local my_ent = loci.entities[loci.my_entity_id]
        if my_ent then
            pred_mod.update_immediate_velocity(my_ent, dx, dy, loci.netcode.default_move_speed)
        end
    end

    loci._send_intent({ move = { direction = { x_bits = entity_mod.float_to_bits(dx), y_bits = entity_mod.float_to_bits(dy) } } })
end

function loci.send_action(ability_id, dir_x, dir_y)
    local aid = tonumber(ability_id) or 0
    local dx = tonumber(dir_x) or 0
    local dy = tonumber(dir_y) or 0
    local len = math.sqrt(dx * dx + dy * dy)

    if len > 0 then
        dx = dx / len
        dy = dy / len
    else
        dx = 0
        dy = 0
    end

    loci._send_intent({ action = { ability_id = aid, target_direction = { x_bits = entity_mod.float_to_bits(dx), y_bits = entity_mod.float_to_bits(dy) } } })
end

function loci.send_action_at_position(ability_id, aim_x, aim_y)
    local my_ent = loci.get_my_entity()
    if not my_ent then return end

    local dx = (tonumber(aim_x) or 0) - (my_ent.x or 0)
    local dy = (tonumber(aim_y) or 0) - (my_ent.y or 0)
    loci.send_action(ability_id, dx, dy)
end

function loci.send_action_direction(ability_id, dir_x, dir_y)
    loci.send_action(ability_id, dir_x, dir_y)
end

function loci.get_entities()
    return entity_mod.get_entities(loci)
end

function loci.get_entities_by_blueprint(blueprint_name)
    return entity_mod.get_entities_by_blueprint(loci, blueprint_name)
end

function loci.get_entities_in_radius(center_x, center_y, radius)
    return entity_mod.get_entities_in_radius(loci, center_x, center_y, radius)
end

function loci.get_my_entity()
    return entity_mod.get_my_entity(loci)
end

function loci.get_globals()
    return entity_mod.get_globals(loci)
end

function loci._interpolate_remote_entity(entity, render_time, tick_rate)
    interp_mod.interpolate_remote_entity(entity, loci._snapshot_buffer, render_time, tick_rate, loci.netcode and loci.netcode.snap_threshold)
end

function loci._dispatch_raw_packet(data)
    protocol_mod.dispatch_raw_packet(loci, schema_mod, data)
end

function loci.update(dt)
    local tick_rate = loci.server_tick_rate or 30.0
    local now = loci._mock_time or socket.gettime()
    local render_time = now - ((loci.netcode and loci.netcode.interpolation_delay) or 0.050)

    -- Check prediction starvation (ADR 0002 Prediction Horizon)
    local pred_timeout = (loci.netcode and loci.netcode.prediction_timeout) or 0.200
    local prediction_starved = pred_mod.is_prediction_starved(loci._last_state_received_time, now, pred_timeout)

    for _, entity in pairs(loci.entities) do
        if loci.my_entity_id and entity.id == loci.my_entity_id then
            if loci.netcode and loci.netcode.prediction_enabled then
                pred_mod.predict_local_player(entity, loci, dt, tick_rate, prediction_starved)
                recon_mod.decay_error(entity, dt, loci.netcode.error_decay_rate or 15.0)
            else
                pred_mod.lerp_server_fallback(entity, dt, tick_rate, (loci.netcode and loci.netcode.snap_threshold) or 50.0, prediction_starved)
            end
        else
            interp_mod.interpolate_remote_entity(entity, loci._snapshot_buffer, render_time, tick_rate, (loci.netcode and loci.netcode.snap_threshold) or 50.0)
        end
    end

    if not loci._udp then return end

    transport_mod.poll_network(loci, now, function(data)
        loci._dispatch_raw_packet(data)
    end)
end

function loci._handle_world_state(state)
    local now = state._receive_time or loci._mock_time or socket.gettime()
    loci._last_state_received_time = now
    loci._last_packet_received_time = now

    -- Store globals with auto-type casting
    loci.globals = {}
    if state.globals then
        for _, prop in ipairs(state.globals) do
            loci.globals[prop.key] = entity_mod.cast_property_value(prop.value)
        end
        -- Auto-detect server tick rate if published in globals
        local pub_rate = tonumber(loci.globals["tick_rate"] or loci.globals["server_tick_rate"])
        if pub_rate and pub_rate > 0 then
            loci.server_tick_rate = pub_rate
        end
    end

    -- Auto-detect server tick rate from authoritative timestamp and tick delta
    if state.tick and state.timestamp and state.tick > 0 and state.timestamp > 0 then
        if loci._last_state_tick and loci._last_state_timestamp then
            local dticks = state.tick - loci._last_state_tick
            local dtime = state.timestamp - loci._last_state_timestamp
            if dticks > 0 and dtime > 0 then
                local estimated_rate = math.floor((dticks * 1000.0 / dtime) + 0.5)
                if estimated_rate >= 10 and estimated_rate <= 240 then
                    loci.server_tick_rate = estimated_rate
                end
            end
        end
        loci._last_state_tick = state.tick
        loci._last_state_timestamp = state.timestamp
    end

    -- Feed NetworkStats telemetry (PR #2)
    if loci.network_stats then
        loci.network_stats:record_snapshot(state.tick, now)
        local fps = 60.0
        if love and love.timer and love.timer.getFPS then
            fps = love.timer.getFPS()
        end
        loci.network_stats:record_telemetry_row(math.floor(now * 1000), state.tick, fps)
    end

    -- Match state synchronization
    if state.match_state ~= nil then
        local state_map = { [0] = "running", [1] = "paused", [2] = "ended" }
        local new_state = state_map[state.match_state] or "running"
        local new_winner = state.match_winner or ""
        if loci.match_state ~= new_state or (new_state == "ended" and loci.match_winner ~= new_winner) then
            loci.match_state = new_state
            loci.match_winner = new_winner
            if loci.on_match_state_changed then
                loci.on_match_state_changed(new_state, new_winner)
            end
        end
    end

    -- Ingest and diff entities
    local new_entities = {}

    if state.entities then
        for _, raw_ent in ipairs(state.entities) do
            local entity_id = raw_ent.id

            -- Detect my_entity
            if loci.my_entity_id == nil and raw_ent.name == loci._player_name then
                loci.my_entity_id = raw_ent.id
                if loci._is_reconnecting then
                    loci._is_reconnecting = false
                    if loci.on_reconnected then
                        pcall(loci.on_reconnected, loci.my_entity_id)
                    end
                end
            end

            local ent = loci.entities[entity_id]
            local is_new = false
            if not ent then
                is_new = true
                ent = entity_mod.new_entity(entity_id, raw_ent.name)
            end

            -- Update Transform
            if raw_ent.position then
                local nx = entity_mod.bits_to_float(raw_ent.position.x_bits)
                local ny = entity_mod.bits_to_float(raw_ent.position.y_bits)
                ent.server_x = nx
                ent.server_y = ny
                if is_new then
                    ent.x = nx
                    ent.y = ny
                elseif loci.my_entity_id and entity_id == loci.my_entity_id and loci.netcode and loci.netcode.prediction_enabled then
                    recon_mod.reconcile_position(ent, nx, ny, loci.netcode.snap_threshold or 50.0, loci.netcode.reconciliation_threshold or 2.0)
                end
            else
                ent.x = ent.x or 0
                ent.y = ent.y or 0
            end

            -- Update Velocity (for interpolation)
            if raw_ent.velocity then
                local svx = entity_mod.bits_to_float(raw_ent.velocity.x_bits)
                local svy = entity_mod.bits_to_float(raw_ent.velocity.y_bits)
                ent.server_vx = svx
                ent.server_vy = svy
                if not (loci.my_entity_id and entity_id == loci.my_entity_id and loci.netcode and loci.netcode.prediction_enabled) then
                    ent.vx = svx
                    ent.vy = svy
                end
            else
                ent.server_vx = 0
                ent.server_vy = 0
                if not (loci.my_entity_id and entity_id == loci.my_entity_id and loci.netcode and loci.netcode.prediction_enabled) then
                    ent.vx = 0
                    ent.vy = 0
                end
            end

            -- Diff properties with auto-casting
            local new_props = {}
            if raw_ent.properties then
                for _, prop in ipairs(raw_ent.properties) do
                    new_props[prop.key] = true
                    local casted_val = entity_mod.cast_property_value(prop.value)
                    local old_val = ent.properties[prop.key]
                    if old_val ~= casted_val then
                        ent.properties[prop.key] = casted_val
                        if not is_new and loci.on_property_changed then
                            loci.on_property_changed(ent, prop.key, old_val, casted_val)
                        end
                    end
                end
            end
            -- Check for removed properties
            local to_remove = {}
            for k, old_val in pairs(ent.properties) do
                if not new_props[k] then
                    table.insert(to_remove, k)
                    if not is_new and loci.on_property_changed then
                        loci.on_property_changed(ent, k, old_val, nil)
                    end
                end
            end
            for _, k in ipairs(to_remove) do
                ent.properties[k] = nil
            end

            if is_new then
                loci.entities[entity_id] = ent
                loci._entities_list_cache = nil
                if loci.on_entity_spawned then
                    loci.on_entity_spawned(ent)
                end
            end

            new_entities[entity_id] = true
        end
    end

    -- Despawn entities not in the new state
    for id, ent in pairs(loci.entities) do
        if not new_entities[id] then
            if loci.on_entity_despawned then
                loci.on_entity_despawned(id)
            end
            loci.entities[id] = nil
            loci._entities_list_cache = nil
            if loci.my_entity_id == id then
                loci.my_entity_id = nil
            end
        end
    end

    -- Process transient action broadcasts
    if state.actions then
        for _, act in ipairs(state.actions) do
            local dir_x, dir_y = 0.0, 0.0
            if act.target_direction then
                dir_x = entity_mod.bits_to_float(act.target_direction.x_bits)
                dir_y = entity_mod.bits_to_float(act.target_direction.y_bits)
            end
            local ent = loci.entities[act.entity_id]
            if ent and loci.on_action_cast then
                loci.on_action_cast(ent, act.ability_id, dir_x, dir_y)
            end
        end
    end

    -- Record snapshot in circular buffer for remote entity interpolation (Phase 1 - ADR 0001)
    buffer_mod.record_snapshot(loci._snapshot_buffer, state.tick, now, loci.entities, loci._max_snapshot_history or 20)
end

function loci._handle_response(resp)
    protocol_mod.handle_response(loci, resp)
end

-- ============================================================================
-- Network Telemetry & Debug APIs (RFC 3550, RTT, Loss & Overlay)
-- ============================================================================

function loci.get_ping()
    return loci.network_stats and loci.network_stats.rtt or 0
end

function loci.get_rtt()
    return loci.get_ping()
end

function loci.get_jitter()
    return loci.network_stats and loci.network_stats.jitter or 0
end

function loci.get_packet_loss()
    return loci.network_stats and loci.network_stats.loss_pct or 0
end

function loci.get_tick_hz()
    return loci.network_stats and loci.network_stats.tick_hz or 0
end

function loci.get_network_stats()
    if loci.network_stats then
        return loci.network_stats:get_stats()
    end
    return {}
end

function loci.record_rtt(rtt_ms)
    if loci.network_stats then
        loci.network_stats:record_rtt(rtt_ms)
    end
end

function loci.toggle_debug_overlay()
    loci.show_debug_overlay = not loci.show_debug_overlay
    return loci.show_debug_overlay
end

function loci.draw_debug_overlay(x, y)
    overlay_mod.draw_overlay(loci.network_stats, loci.show_debug_overlay, x, y)
end

function loci.draw()
    if loci.show_debug_overlay then
        loci.draw_debug_overlay(10, 10)
    end
end

function loci.export_network_stats_csv(filepath)
    if loci.network_stats then
        local path, count = loci.network_stats:export_csv(filepath)
        if path then
            print(string.format("[NetworkStats] Telemetry exported to: %s (%d snapshots)", path, count or 0))
            return path
        end
    end
    return nil
end

function loci.keypressed(key)
    if key == "f3" then
        loci.toggle_debug_overlay()
        return true
    elseif key == "f4" then
        loci.export_network_stats_csv()
        return true
    end
    return false
end

function loci.quit()
    if loci.netcode and loci.netcode.auto_export_csv_on_quit then
        loci.export_network_stats_csv()
    end
end

return loci
