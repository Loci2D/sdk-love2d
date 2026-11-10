-- ============================================================================
-- Loci2D - Protocol Encoding, Decoding, and Dispatching Module
-- Handles GamePacket encoding, ServerPacket decoding, and response routing.
-- ============================================================================

local socket = require("socket")
local protocol_module = {}

function protocol_module.encode_game_packet(pb, sequence_id, now_sec, intent_table)
    if not pb then return nil end

    local packet = {
        sequence_id = sequence_id,
        timestamp = math.floor(now_sec * 1000),
        intent = intent_table
    }

    return pb.encode("loci2d.GamePacket", packet)
end

function protocol_module.decode_server_packet(pb, data)
    if not pb or not data then return false, nil end
    return pcall(pb.decode, "loci2d.ServerPacket", data)
end

function protocol_module.deliver_encoded_packet(ctx, data, now_sec)
    if not ctx._udp or not data then return end

    local loss_rate = (ctx.netcode and ctx.netcode.simulate_packet_loss) or 0.0
    if loss_rate > 0 and math.random() < loss_rate then
        -- Intentionally dropped in synthetic uplink simulator
        return
    end

    local sim_latency = (ctx.netcode and ctx.netcode.simulate_latency) or 0.0
    if sim_latency > 0 then
        local send_at = (now_sec or ctx._mock_time or socket.gettime()) + sim_latency
        if not ctx._delayed_outbound_queue then
            ctx._delayed_outbound_queue = {}
        end
        table.insert(ctx._delayed_outbound_queue, {
            deliver_at = send_at,
            data = data
        })
    else
        ctx._udp:send(data)
    end
end

function protocol_module.send_intent(ctx, schema, intent_table)
    local pb = schema.get_pb()
    if not pb or not ctx._schema_loaded or not ctx._udp then return end

    ctx._sequence_id = (ctx._sequence_id or 0) + 1
    local now_sec = ctx._mock_time or socket.gettime()

    if not ctx._inflight_intents then
        ctx._inflight_intents = {}
    end
    ctx._inflight_intents[ctx._sequence_id] = now_sec

    local data = protocol_module.encode_game_packet(pb, ctx._sequence_id, now_sec, intent_table)
    if data then
        -- Send disconnect bypasses synthetic delay queue since socket closes immediately
        if intent_table and intent_table.disconnect ~= nil then
            ctx._udp:send(data)
        else
            protocol_module.deliver_encoded_packet(ctx, data, now_sec)
        end
    end
end

function protocol_module.dispatch_raw_packet(ctx, schema, data)
    if not ctx._schema_loaded then return end
    local pb = schema.get_pb()
    if not pb then return end

    local ok, packet = protocol_module.decode_server_packet(pb, data)
    if ok and packet then
        local now = ctx._mock_time or socket.gettime()

        -- RTT Resolution via inflight intent sequence mapping
        local ack_seq = (packet.response and packet.response.sequence_id) or packet.sequence_id
        if ack_seq and ctx._inflight_intents and ctx._inflight_intents[ack_seq] then
            local send_t = ctx._inflight_intents[ack_seq]
            local rtt_ms = (now - send_t) * 1000.0
            if rtt_ms >= 0 and rtt_ms < 5000 then
                if ctx.network_stats then
                    ctx.network_stats:record_rtt(rtt_ms)
                end
            end
            ctx._inflight_intents[ack_seq] = nil
        end

        if packet.world_state then
            ctx._handle_world_state(packet.world_state)
        elseif packet.response then
            ctx._handle_response(packet.response)
        end
    elseif not ok then
        print("[Error] pb.decode failed: " .. tostring(packet))
    end
end

function protocol_module.handle_response(ctx, resp)
    if resp and resp.status then
        local prefix = "rejected: "
        if string.sub(resp.status, 1, string.len(prefix)) == prefix then
            local reason = string.sub(resp.status, string.len(prefix) + 1)
            if ctx.on_intent_rejected then
                ctx.on_intent_rejected(reason)
            end
        end
    end
end

return protocol_module
