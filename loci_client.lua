local socket = require("socket")
local pb = nil
local protoc = nil

-- Discover directory of current script to locate adjacent 'lib/' folder
local script_dir = ""
local info = debug.getinfo(1, "S")
if info and info.source and info.source:sub(1, 1) == "@" then
    local src_path = info.source:sub(2)
    script_dir = src_path:match("^(.*[/\\])") or ""
end

local cpath_candidates = {
    script_dir .. "lib/?.so",
    script_dir .. "lib/?.dylib",
    script_dir .. "lib/?.dll",
    script_dir .. "?.so",
    script_dir .. "?.dylib",
    script_dir .. "?.dll",
    "./?.so", "./lib/?.so", "./loci2d/lib/?.so", "./client/loci2d/lib/?.so",
    "./?.dylib", "./lib/?.dylib", "./loci2d/lib/?.dylib", "./client/loci2d/lib/?.dylib",
    "./?.dll", "./lib/?.dll", "./loci2d/lib/?.dll", "./client/loci2d/lib/?.dll",
    "sdks/love2d/lib/?.so", "../../sdks/love2d/lib/?.so"
}
for _, pat in ipairs(cpath_candidates) do
    if not package.cpath:find(pat, 1, true) then
        package.cpath = package.cpath .. ";" .. pat
    end
end

local path_candidates = {
    script_dir .. "lib/?.lua",
    script_dir .. "?.lua",
    "./?.lua", "./lib/?.lua", "./loci2d/lib/?.lua", "./client/loci2d/lib/?.lua",
    "./loci2d/?.lua", "./client/loci2d/?.lua",
    "sdks/love2d/lib/?.lua", "../../sdks/love2d/lib/?.lua"
}
for _, pat in ipairs(path_candidates) do
    if not package.path:find(pat, 1, true) then
        package.path = package.path .. ";" .. pat
    end
end

-- Attempt to load lua-protobuf library and protoc parser
local ok_pb, res_pb = pcall(require, "pb")
if ok_pb then
    pb = res_pb
    local ok_protoc, res_protoc = pcall(require, "protoc")
    if ok_protoc then
        protoc = res_protoc
    end
else
    print("[Warning] 'lua-protobuf' module not found.")
    print("Install lua-protobuf (e.g. via luarocks install lua-protobuf) to run full binary Protobuf encoding.")
end

-- Load NetworkStats telemetry module
local NetworkStats = nil
local ok_netstats, res_netstats = pcall(require, "network_stats")
if ok_netstats then
    NetworkStats = res_netstats
else
    local ok_lib_ns, res_lib_ns = pcall(require, "lib.network_stats")
    if ok_lib_ns then
        NetworkStats = res_lib_ns
    end
end

local function bits_to_float(bits)
    if not bits then return 0.0 end
    return bits / 65536.0
end

local function float_to_bits(f)
    if not f then return 0 end
    return math.floor(f * 65536)
end

local function cast_property_value(val)
    if type(val) ~= "string" then return val end
    if val == "true" or val == "True" then return true end
    if val == "false" or val == "False" then return false end
    local num = tonumber(val)
    if num ~= nil then return num end
    return val
end

local loci

-- ============================================================================
-- High-Level Entity Abstraction (Phase 6.5.3-1)
-- ============================================================================
local Entity = {}
Entity.__index = function(t, k)
    local method = Entity[k]
    if method ~= nil then return method end
    local props = rawget(t, "properties")
    if props ~= nil then
        return props[k]
    end
    return nil
end

function Entity:is_local_player()
    return loci and self.id == loci.my_entity_id
end

function Entity:distance_to(other_or_pos)
    if not other_or_pos then return 0 end
    local ox = other_or_pos.x or 0
    local oy = other_or_pos.y or 0
    local dx = self.x - ox
    local dy = self.y - oy
    return math.sqrt(dx * dx + dy * dy)
end

function Entity:get(prop_name, default_value)
    local props = rawget(self, "properties")
    if props and props[prop_name] ~= nil then
        return props[prop_name]
    end
    return default_value
end

local function new_entity(id, blueprint)
    local ent = {
        id = id,
        blueprint = blueprint,
        x = 0,
        y = 0,
        vx = 0,
        vy = 0,
        server_x = nil,
        server_y = nil,
        server_vx = 0,
        server_vy = 0,
        _error_x = 0,
        _error_y = 0,
        properties = {}
    }
    setmetatable(ent, Entity)
    return ent
end

-- ============================================================================
-- Loci Client Module Facade
-- ============================================================================
loci = {
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

        -- Diagnostic & synthetic testing
        simulate_packet_loss = 0.0,       -- 0.0 to 1.0 (e.g. 0.15 = 15% random drop)
        simulate_latency = 0.0,           -- Simulated delay in seconds (e.g. 0.050 = 50ms)
        auto_export_csv_on_quit = true,   -- Automatically export network telemetry CSV on disconnect/quit
        telemetry_window_size = 120,      -- Rolling window size for RTT / Jitter (Zero-GC circular buffer)
    },

    -- Network Telemetry & Debug HUD
    show_debug_overlay = false,
    network_stats = NetworkStats and NetworkStats.new({ capacity = 120 }) or nil,

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
    if base_path then
        loci._base_path = base_path
    end
    if tick_rate and tonumber(tick_rate) and tonumber(tick_rate) > 0 then
        loci.server_tick_rate = tonumber(tick_rate)
    end

    loci._udp = socket.udp()
    loci._udp:settimeout(0)
    loci._udp:setpeername(host, port)
    loci._player_name = player_name
    
    if pb then
        local schema_loaded = false
        local candidate_proto_paths = {
            loci._base_path and (loci._base_path .. "game_packets.proto"),
            loci._base_path and (loci._base_path .. "/game_packets.proto"),
            script_dir ~= "" and (script_dir .. "lib/game_packets.proto") or nil,
            script_dir ~= "" and (script_dir .. "game_packets.proto") or nil,
            "lib/game_packets.proto",
            "loci2d/lib/game_packets.proto",
            "client/loci2d/lib/game_packets.proto",
            "sdks/love2d/lib/game_packets.proto",
            "../../sdks/love2d/lib/game_packets.proto",
            "proto/game_packets.proto",
            "../../proto/game_packets.proto",
            "game_packets.proto",
        }

        local function read_proto_file(path)
            if not path then return nil end
            local f = io.open(path, "r")
            if f then
                local content = f:read("*a")
                f:close()
                if content and #content > 0 then return content end
            end
            if love and love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo(path) then
                local content, _ = love.filesystem.read(path)
                if content and #content > 0 then return content end
            end
            return nil
        end

        -- 1. Try dynamic text parsing with protoc.lua
        if protoc then
            local p = protoc.new()
            p.include_dirs = { loci._base_path, script_dir .. "lib", "lib", "loci2d/lib", "client/loci2d/lib", "sdks/love2d/lib", "proto", "../../proto", "." }

            for _, path in ipairs(candidate_proto_paths) do
                local content = read_proto_file(path)
                if content then
                    local ok, _ = pcall(function() return p:load(content, "game_packets.proto") end)
                    if ok then
                        schema_loaded = true
                        break
                    end
                end
            end
        end

        -- 2. Fallback: try loading compiled .pb descriptor file
        if not schema_loaded then
            local candidate_pb_paths = {
                loci._base_path and (loci._base_path .. "game_packets.pb"),
                loci._base_path and (loci._base_path .. "/game_packets.pb"),
                script_dir ~= "" and (script_dir .. "lib/game_packets.pb") or nil,
                script_dir ~= "" and (script_dir .. "game_packets.pb") or nil,
                "lib/game_packets.pb",
                "loci2d/lib/game_packets.pb",
                "client/loci2d/lib/game_packets.pb",
                "sdks/love2d/lib/game_packets.pb",
                "../../sdks/love2d/lib/game_packets.pb",
                "game_packets.pb",
            }
            for _, path in ipairs(candidate_pb_paths) do
                local ok, res = pcall(function() return pb.loadfile(path) end)
                if ok and res then
                    schema_loaded = true
                    break
                end
            end
        end

        loci._schema_loaded = schema_loaded
        
        if schema_loaded then
            loci._send_intent({ join = { player_name = player_name, schema_version = loci.SCHEMA_VERSION } })
            return true
        else
            print("[Error] Could not load game_packets schema definition. Aborting network.")
            loci._udp:close()
            loci._udp = nil
            return false
        end
    end
    
    return false
end

function loci.disconnect(reason)
    if loci.netcode and loci.netcode.auto_export_csv_on_quit then
        pcall(function() loci.export_network_stats_csv() end)
    end
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
        loci._udp:close()
        loci._udp = nil
    end
end

function loci._send_intent(intent_table)
    if not pb or not loci._schema_loaded or not loci._udp then return end

    loci._sequence_id = loci._sequence_id + 1
    local now = loci._mock_time or socket.gettime()
    local now_ms = math.floor(now * 1000)

    -- Track sent timestamp for Round-Trip Time (RTT) measurement
    if not loci._inflight_intents then
        loci._inflight_intents = {}
    end
    loci._inflight_intents[loci._sequence_id] = now

    -- Periodic cleanup of unacknowledged inflight requests older than 5s
    if loci._sequence_id % 64 == 0 then
        for seq, t in pairs(loci._inflight_intents) do
            if (now - t) > 5.0 then
                loci._inflight_intents[seq] = nil
            end
        end
    end

    local packet = {
        sequence_id = loci._sequence_id,
        timestamp = now_ms,
        intent = intent_table
    }

    local data = pb.encode("loci2d.GamePacket", packet)
    if data then
        loci._udp:send(data)
    end
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
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0 then
                local move_speed = tonumber(my_ent:get("move_speed") or my_ent:get("speed") or loci.netcode.default_move_speed) or 3.0
                my_ent.vx = (dx / len) * move_speed
                my_ent.vy = (dy / len) * move_speed
            else
                my_ent.vx = 0
                my_ent.vy = 0
            end
        end
    end

    loci._send_intent({ move = { direction = { x_bits = float_to_bits(dx), y_bits = float_to_bits(dy) } } })
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

    loci._send_intent({ action = { ability_id = aid, target_direction = { x_bits = float_to_bits(dx), y_bits = float_to_bits(dy) } } })
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

-- Cached to avoid GC pressure, returns a pooled shallow copy to prevent internal cache mutation
function loci.get_entities()
    if not loci._entities_list_cache then
        local list = {}
        for _, e in pairs(loci.entities) do
            table.insert(list, e)
        end
        loci._entities_list_cache = list
    end
    
    if not loci._public_entities_list then
        loci._public_entities_list = {}
    end
    
    -- Clear and refill the public list to prevent internal cache corruption
    local public_list = loci._public_entities_list
    for i = 1, #public_list do
        public_list[i] = nil
    end
    for i = 1, #loci._entities_list_cache do
        public_list[i] = loci._entities_list_cache[i]
    end
    
    return public_list
end

function loci.get_entities_by_blueprint(blueprint_name)
    local list = {}
    for _, e in pairs(loci.entities) do
        if e.blueprint == blueprint_name then
            table.insert(list, e)
        end
    end
    return list
end

function loci.get_entities_in_radius(center_x, center_y, radius)
    local list = {}
    local r2 = radius * radius
    for _, e in pairs(loci.entities) do
        local dx = e.x - center_x
        local dy = e.y - center_y
        if (dx * dx + dy * dy) <= r2 then
            table.insert(list, e)
        end
    end
    return list
end

function loci.get_my_entity()
    if loci.my_entity_id then
        return loci.entities[loci.my_entity_id]
    end
    return nil
end

function loci.get_globals()
    return loci.globals
end

function loci._interpolate_remote_entity(entity, render_time, tick_rate)
    local buffer = loci._snapshot_buffer
    local buf_len = #buffer

    if buf_len >= 2 then
        local s1, s2 = nil, nil
        for i = buf_len, 2, -1 do
            if buffer[i - 1].receive_time <= render_time then
                s1 = buffer[i - 1]
                s2 = buffer[i]
                break
            end
        end

        if s1 and s2 then
            local p1 = s1.entities[entity.id]
            local p2 = s2.entities[entity.id]
            if p1 and p2 then
                local span = s2.receive_time - s1.receive_time
                local alpha = (span > 0) and math.min(1.0, math.max(0.0, (render_time - s1.receive_time) / span)) or 1.0
                local dx = p2.x - p1.x
                local dy = p2.y - p1.y
                local snap_thresh = loci.netcode.snap_threshold or 50.0

                if (dx * dx + dy * dy) > (snap_thresh * snap_thresh) then
                    -- Hard teleport / rubberband: do not interpolate across map
                    if alpha >= 0.5 then
                        entity.x = p2.x
                        entity.y = p2.y
                        entity.vx = p2.vx or 0
                        entity.vy = p2.vy or 0
                    else
                        entity.x = p1.x
                        entity.y = p1.y
                        entity.vx = p1.vx or 0
                        entity.vy = p1.vy or 0
                    end
                else
                    entity.x = p1.x + dx * alpha
                    entity.y = p1.y + dy * alpha
                    entity.vx = (p1.vx or 0) + ((p2.vx or 0) - (p1.vx or 0)) * alpha
                    entity.vy = (p1.vy or 0) + ((p2.vy or 0) - (p1.vy or 0)) * alpha
                end
            elseif p2 then
                entity.x = p2.x
                entity.y = p2.y
                entity.vx = p2.vx or 0
                entity.vy = p2.vy or 0
            elseif p1 then
                entity.x = p1.x
                entity.y = p1.y
                entity.vx = p1.vx or 0
                entity.vy = p1.vy or 0
            end
        elseif render_time > buffer[buf_len].receive_time then
            -- Packet starvation / jitter: extrapolate slightly (up to 100ms) from newest snapshot
            local newest = buffer[buf_len]
            local p_new = newest.entities[entity.id]
            if p_new then
                local overdue = render_time - newest.receive_time
                if overdue <= 0.100 then
                    local vx_sec = (p_new.vx or 0) * tick_rate
                    local vy_sec = (p_new.vy or 0) * tick_rate
                    entity.x = p_new.x + vx_sec * overdue
                    entity.y = p_new.y + vy_sec * overdue
                else
                    entity.x = p_new.x
                    entity.y = p_new.y
                end
                entity.vx = p_new.vx or 0
                entity.vy = p_new.vy or 0
            end
        elseif render_time < buffer[1].receive_time then
            -- Render time is before oldest buffered state
            local oldest = buffer[1]
            local p_old = oldest.entities[entity.id]
            if p_old then
                entity.x = p_old.x
                entity.y = p_old.y
                entity.vx = p_old.vx or 0
                entity.vy = p_old.vy or 0
            end
        end
    elseif buf_len == 1 then
        local p = buffer[1].entities[entity.id]
        if p then
            entity.x = p.x
            entity.y = p.y
            entity.vx = p.vx or 0
            entity.vy = p.vy or 0
        end
    else
        -- Fallback if no snapshots yet
        if entity.server_x and entity.server_y then
            entity.x = entity.server_x
            entity.y = entity.server_y
        end
    end
end

function loci._dispatch_raw_packet(data)
    if not loci._schema_loaded or not pb then return end
    local ok, packet = pcall(pb.decode, "loci2d.ServerPacket", data)
    if ok and packet then
        local now = loci._mock_time or socket.gettime()

        -- Measure RTT if this packet acknowledges an inflight intent sequence
        local ack_seq = (packet.response and packet.response.sequence_id) or packet.sequence_id
        if ack_seq and loci._inflight_intents and loci._inflight_intents[ack_seq] then
            local send_t = loci._inflight_intents[ack_seq]
            local rtt_ms = (now - send_t) * 1000.0
            if loci.network_stats then
                loci.network_stats:record_rtt(rtt_ms)
            end
            loci._inflight_intents[ack_seq] = nil
        end

        if packet.world_state then
            loci._handle_world_state(packet.world_state)
        elseif packet.response then
            loci._handle_response(packet.response)
        end
    elseif not ok then
        print("[Error] pb.decode failed: " .. tostring(packet))
    end
end

function loci.update(dt)
    local tick_rate = loci.server_tick_rate or 30.0
    local now = loci._mock_time or socket.gettime()
    local render_time = now - (loci.netcode.interpolation_delay or 0.050)

    -- Check prediction starvation (ADR 0002 Prediction Horizon)
    local pred_timeout = (loci.netcode and loci.netcode.prediction_timeout) or 0.200
    local prediction_starved = false
    if loci._last_state_received_time ~= nil then
        if (now - loci._last_state_received_time) > pred_timeout then
            prediction_starved = true
        end
    end

    for _, entity in pairs(loci.entities) do
        if loci.my_entity_id and entity.id == loci.my_entity_id then
            if loci.netcode and loci.netcode.prediction_enabled then
                -- Client-Side Prediction (Phase 2 - ADR 0001 & ADR 0002)
                local is_dead_prop = entity:get("is_dead")
                local is_dead = (is_dead_prop == "true" or is_dead_prop == true or is_dead_prop == 1 or is_dead_prop == "1")
                local cur_tick = loci._last_state_tick or 0
                local stunned_until = tonumber(entity:get("stunned_until")) or 0
                local paralyzed_until = tonumber(entity:get("paralyzed_until")) or 0
                local dashing_until = tonumber(entity:get("dashing_until")) or 0
                local incapacitated = is_dead or (cur_tick < stunned_until) or (cur_tick < paralyzed_until)

                if incapacitated or prediction_starved then
                    entity.vx = 0
                    entity.vy = 0
                elseif cur_tick < dashing_until then
                    -- Dash active: let server physical velocity guide displacement
                    local vx_sec = (entity.vx or 0) * tick_rate
                    local vy_sec = (entity.vy or 0) * tick_rate
                    entity.x = entity.x + vx_sec * dt
                    entity.y = entity.y + vy_sec * dt
                elseif loci._prediction_handler then
                    -- Pluggable prediction hook for custom physics
                    loci._prediction_handler(entity, loci._active_move_dx or 0, loci._active_move_dy or 0, dt)
                else
                    -- Default Kinematic Prediction
                    local in_dx = loci._active_move_dx or 0
                    local in_dy = loci._active_move_dy or 0
                    local len = math.sqrt(in_dx * in_dx + in_dy * in_dy)

                    if len > 0 then
                        local ndx = in_dx / len
                        local ndy = in_dy / len
                        local move_speed = tonumber(entity:get("move_speed") or entity:get("speed") or loci.netcode.default_move_speed) or 3.0
                        local speed_sec = move_speed * tick_rate

                        entity.x = entity.x + ndx * speed_sec * dt
                        entity.y = entity.y + ndy * speed_sec * dt
                        entity.vx = ndx * move_speed
                        entity.vy = ndy * move_speed
                    else
                        entity.vx = 0
                        entity.vy = 0
                    end
                end

                -- Smooth exponential error decay (Phase 3 reconciliation)
                if (entity._error_x and entity._error_x ~= 0) or (entity._error_y and entity._error_y ~= 0) then
                    local decay_rate = loci.netcode.error_decay_rate or 15.0
                    local decay = math.exp(-decay_rate * dt)
                    local step_x = entity._error_x * (1.0 - decay)
                    local step_y = entity._error_y * (1.0 - decay)
                    entity.x = entity.x + step_x
                    entity.y = entity.y + step_y
                    entity._error_x = entity._error_x * decay
                    entity._error_y = entity._error_y * decay
                    if math.abs(entity._error_x) < 0.01 and math.abs(entity._error_y) < 0.01 then
                        entity._error_x = 0
                        entity._error_y = 0
                    end
                end
            else
                -- Fallback when prediction is disabled: Lerp towards theoretical server position
                if prediction_starved then
                    entity.vx = 0
                    entity.vy = 0
                else
                    local vx_sec = (entity.vx or 0) * tick_rate
                    local vy_sec = (entity.vy or 0) * tick_rate

                    if entity.server_x and entity.server_y then
                        entity.server_x = entity.server_x + vx_sec * dt
                        entity.server_y = entity.server_y + vy_sec * dt
                        
                        local dx = entity.server_x - entity.x
                        local dy = entity.server_y - entity.y
                        local dist2 = dx * dx + dy * dy
                        local snap_thresh = loci.netcode.snap_threshold or 50.0

                        if dist2 > (snap_thresh * snap_thresh) then
                            entity.x = entity.server_x
                            entity.y = entity.server_y
                        elseif dist2 > 0.01 then
                            entity.x = entity.x + dx * math.min(1.0, 15.0 * dt)
                            entity.y = entity.y + dy * math.min(1.0, 15.0 * dt)
                        else
                            entity.x = entity.x + vx_sec * dt
                            entity.y = entity.y + vy_sec * dt
                        end
                    else
                        entity.x = entity.x + vx_sec * dt
                        entity.y = entity.y + vy_sec * dt
                    end
                end
            end
        else
            -- Remote entities: Snapshot Interpolation (Phase 1 - ADR 0001)
            loci._interpolate_remote_entity(entity, render_time, tick_rate)
        end
    end

    if not loci._udp then return end

    -- Connection Watchdog (ADR 0002)
    local conn_timeout = (loci.netcode and loci.netcode.connection_timeout) or 4.0
    if loci.my_entity_id ~= nil and loci._last_packet_received_time ~= nil then
        if (now - loci._last_packet_received_time) > conn_timeout then
            -- Declared disconnected due to silence
            local old_id = loci.my_entity_id
            loci.my_entity_id = nil
            loci._snapshot_buffer = {}
            loci._active_move_dx = 0
            loci._active_move_dy = 0
            loci._is_reconnecting = true
            loci._last_join_attempt_time = now
            if loci.on_connection_lost then
                pcall(loci.on_connection_lost, "heartbeat timeout")
            end
            if loci.netcode and loci.netcode.auto_reconnect and loci._player_name then
                loci._send_intent({ join = { player_name = loci._player_name, schema_version = loci.SCHEMA_VERSION } })
            end
        end
    end

    -- Heartbeat / Join Intent cadence (ADR 0002: accelerated 400ms heartbeat)
    local heartbeat_interval = (loci.netcode and loci.netcode.heartbeat_interval) or 0.400
    if loci.my_entity_id == nil and loci._player_name then
        local retry_interval = loci._is_reconnecting and 1.0 or 2.0
        if (now - loci._last_join_attempt_time) >= retry_interval then
            loci._last_join_attempt_time = now
            loci._send_intent({ join = { player_name = loci._player_name, schema_version = loci.SCHEMA_VERSION } })
        end
    else
        -- Accelerated heartbeat ping once connected (ADR 0002)
        if (now - loci._last_heartbeat_time) >= heartbeat_interval then
            loci._last_heartbeat_time = now
            loci._send_intent({ ping = {} })
        end
    end

    -- Process queued delayed packets (Synthetic Latency Simulator)
    if loci._delayed_packet_queue and #loci._delayed_packet_queue > 0 then
        local remaining = {}
        for _, delayed in ipairs(loci._delayed_packet_queue) do
            if now >= delayed.deliver_at then
                loci._dispatch_raw_packet(delayed.data)
            else
                table.insert(remaining, delayed)
            end
        end
        loci._delayed_packet_queue = remaining
    end

    while true do
        local data, err = loci._udp:receive(65536)
        if not data then
            break
        end

        loci._last_packet_received_time = now

        -- Synthetic Packet Loss Simulator
        local loss_rate = (loci.netcode and loci.netcode.simulate_packet_loss) or 0.0
        if loss_rate > 0 and math.random() < loss_rate then
            -- Intentionally dropped
        else
            local sim_latency = (loci.netcode and loci.netcode.simulate_latency) or 0.0
            if sim_latency > 0 then
                table.insert(loci._delayed_packet_queue, {
                    deliver_at = now + sim_latency,
                    data = data
                })
            else
                loci._dispatch_raw_packet(data)
            end
        end
    end
end

function loci._handle_world_state(state)
    local now = state._receive_time or loci._mock_time or socket.gettime()
    loci._last_state_received_time = now
    loci._last_packet_received_time = now

    -- Record snapshot into network telemetry
    if loci.network_stats then
        loci.network_stats:record_snapshot(state.tick, now)
        local fps = 60.0
        if love and love.timer and love.timer.getFPS then
            fps = love.timer.getFPS()
        end
        loci.network_stats:record_telemetry_row(math.floor(now * 1000), state.tick, fps)
    end

    -- Store globals with auto-type casting
    loci.globals = {}
    if state.globals then
        for _, prop in ipairs(state.globals) do
            loci.globals[prop.key] = cast_property_value(prop.value)
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

    -- Match state synchronization
    if state.match_state ~= nil then
        local state_map = { [0] = "running", [1] = "paused", [2] = "ended" }
        local new_state = state_map[state.match_state] or "running"
        local new_winner = state.match_winner or ""
        if loci.match_state ~= new_state or (new_state == "ended" and loci.match_winner ~= new_winner) then
            loci.match_state = new_state
            loci.match_winner = new_winner
            loci.on_match_state_changed(new_state, new_winner)
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
                ent = new_entity(entity_id, raw_ent.name)
            end
            
            -- Update Transform
            if raw_ent.position then
                local nx = bits_to_float(raw_ent.position.x_bits)
                local ny = bits_to_float(raw_ent.position.y_bits)
                ent.server_x = nx
                ent.server_y = ny
                if is_new then
                    ent.x = nx
                    ent.y = ny
                elseif loci.my_entity_id and entity_id == loci.my_entity_id and loci.netcode and loci.netcode.prediction_enabled then
                    -- Reconcile predicted position with authoritative server position
                    local err_x = nx - ent.x
                    local err_y = ny - ent.y
                    local dist2 = err_x * err_x + err_y * err_y
                    local snap_thresh = loci.netcode.snap_threshold or 50.0
                    local rec_thresh = loci.netcode.reconciliation_threshold or 2.0

                    if dist2 > (snap_thresh * snap_thresh) then
                        -- Critical error: hard snap (teleport, respawn, hard knockback)
                        ent.x = nx
                        ent.y = ny
                        ent._error_x = 0
                        ent._error_y = 0
                    elseif dist2 > (rec_thresh * rec_thresh) then
                        -- Moderate error: store error offset for exponential decay smoothing
                        ent._error_x = err_x
                        ent._error_y = err_y
                    else
                        -- Negligible error (< 2px): ignore micro-discrepancy
                        ent._error_x = 0
                        ent._error_y = 0
                    end
                end
            else
                ent.x = ent.x or 0
                ent.y = ent.y or 0
            end
            
            -- Update Velocity (for interpolation)
            if raw_ent.velocity then
                local svx = bits_to_float(raw_ent.velocity.x_bits)
                local svy = bits_to_float(raw_ent.velocity.y_bits)
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
                    local casted_val = cast_property_value(prop.value)
                    local old_val = ent.properties[prop.key]
                    if old_val ~= casted_val then
                        ent.properties[prop.key] = casted_val
                        if not is_new then
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
                    if not is_new then
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
                loci.on_entity_spawned(ent)
            end
            
            new_entities[entity_id] = true
        end
    end
    
    -- Despawn entities not in the new state
    for id, ent in pairs(loci.entities) do
        if not new_entities[id] then
            loci.on_entity_despawned(id)
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
                dir_x = bits_to_float(act.target_direction.x_bits)
                dir_y = bits_to_float(act.target_direction.y_bits)
            end
            local ent = loci.entities[act.entity_id]
            if ent then
                loci.on_action_cast(ent, act.ability_id, dir_x, dir_y)
            end
        end
    end

    -- Record snapshot in circular buffer for remote entity interpolation (Phase 1 - ADR 0001)
    local snap_entities = {}
    for id, ent in pairs(loci.entities) do
        snap_entities[id] = {
            x = ent.server_x or ent.x or 0,
            y = ent.server_y or ent.y or 0,
            vx = ent.vx or 0,
            vy = ent.vy or 0
        }
    end
    table.insert(loci._snapshot_buffer, {
        tick = state.tick or 0,
        receive_time = state._receive_time or loci._mock_time or socket.gettime(),
        entities = snap_entities
    })
    while #loci._snapshot_buffer > (loci._max_snapshot_history or 20) do
        table.remove(loci._snapshot_buffer, 1)
    end
end

function loci._handle_response(resp)
    if resp.status then
        local prefix = "rejected: "
        if string.sub(resp.status, 1, string.len(prefix)) == prefix then
            local reason = string.sub(resp.status, string.len(prefix) + 1)
            loci.on_intent_rejected(reason)
        end
    end
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
    if not loci.show_debug_overlay then return end
    if not love or not love.graphics then return end

    x = x or 10
    y = y or 10
    local stats_str = loci.network_stats and loci.network_stats:get_summary_string() or "[REDE] Telemetria inativa"

    local font = love.graphics.getFont()
    local text_w = font and font:getWidth(stats_str) or 520
    local text_h = font and font:getHeight() or 16
    local pad_x = 8
    local pad_y = 6
    local box_w = text_w + pad_x * 2
    local box_h = text_h + pad_y * 2

    local r, g, b, a = love.graphics.getColor()

    -- Semi-transparent dark background (Zero GC rendering)
    love.graphics.setColor(0.05, 0.05, 0.05, 0.82)
    love.graphics.rectangle("fill", x, y, box_w, box_h, 4, 4)

    -- Subtle accent outline
    love.graphics.setColor(0.2, 0.8, 0.4, 0.9)
    love.graphics.rectangle("line", x, y, box_w, box_h, 4, 4)

    -- Status text
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(stats_str, x + pad_x, y + pad_y)

    -- Restore previous color state
    love.graphics.setColor(r, g, b, a)
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
