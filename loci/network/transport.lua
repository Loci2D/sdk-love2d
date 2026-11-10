-- ============================================================================
-- Loci2D - Transport & Network Lifecycle Module
-- UDP socket management, heartbeat cadence, silence watchdogs, and auto-reconnection.
-- ============================================================================

local socket = require("socket")
local transport_module = {}

function transport_module.create_udp(host, port)
    local udp = socket.udp()
    if udp then
        udp:settimeout(0)
        udp:setpeername(host, port)
    end
    return udp
end

function transport_module.close_udp(udp)
    if udp and udp.close then
        pcall(function() udp:close() end)
    end
end

function transport_module.poll_network(ctx, now, on_dispatch_packet, is_incapacitated)
    if not ctx._udp then return end

    -- 1. Connection Watchdog (ADR 0002)
    local conn_timeout = (ctx.netcode and ctx.netcode.connection_timeout) or 4.0
    if ctx.my_entity_id ~= nil and ctx._last_packet_received_time ~= nil then
        if (now - ctx._last_packet_received_time) > conn_timeout then
            ctx.my_entity_id = nil
            ctx._snapshot_buffer = {}
            ctx._active_move_dx = 0
            ctx._active_move_dy = 0
            ctx._active_move_cleared_by_timeout = true
            ctx._stop_redundancy_remaining = 0
            ctx._was_incapacitated_with_move = false
            ctx._is_reconnecting = true
            ctx._last_join_attempt_time = now
            if ctx.on_connection_lost then
                pcall(ctx.on_connection_lost, "heartbeat timeout")
            end
            if ctx.netcode and ctx.netcode.auto_reconnect and ctx._player_name and ctx._send_intent then
                ctx._send_intent({ join = { player_name = ctx._player_name, schema_version = ctx.SCHEMA_VERSION } })
            end
        end
    end

    -- 2. Heartbeat / Join Intent cadence (ADR 0002: accelerated 400ms heartbeat)
    local heartbeat_interval = (ctx.netcode and ctx.netcode.heartbeat_interval) or 0.400
    if ctx.my_entity_id == nil and ctx._player_name then
        local retry_interval = ctx._is_reconnecting and 1.0 or 2.0
        if (now - (ctx._last_join_attempt_time or 0)) >= retry_interval then
            ctx._last_join_attempt_time = now
            if ctx._send_intent then
                ctx._send_intent({ join = { player_name = ctx._player_name, schema_version = ctx.SCHEMA_VERSION } })
            end
        end
    else
        -- Accelerated heartbeat ping once connected (ADR 0002)
        if (now - (ctx._last_heartbeat_time or 0)) >= heartbeat_interval then
            ctx._last_heartbeat_time = now
            if ctx._send_intent then
                ctx._send_intent({ ping = {} })
            end
        end

        -- 2b. MoveIntent Uplink Reliability (ADR 0003: Keepalive, CC recovery & stop redundancy)
        local dx = ctx._active_move_dx or 0
        local dy = ctx._active_move_dy or 0
        if dx ~= 0 or dy ~= 0 then
            if is_incapacitated then
                -- Defer retransmission while dead/stunned/paralyzed to avoid rejection banner spam
                ctx._was_incapacitated_with_move = true
            else
                local keepalive_interval = (ctx.netcode and ctx.netcode.intent_keepalive_interval) or 0.100
                local should_resend = ctx._was_incapacitated_with_move == true
                if not should_resend and keepalive_interval > 0 then
                    if ctx._last_move_sent_time == nil or (now - ctx._last_move_sent_time) >= keepalive_interval then
                        should_resend = true
                    end
                end
                if should_resend then
                    ctx._was_incapacitated_with_move = false
                    ctx._last_move_sent_time = now
                    if ctx._send_move_packet then
                        ctx._send_move_packet(dx, dy)
                    end
                end
            end
        else
            ctx._was_incapacitated_with_move = false
            if (ctx._stop_redundancy_remaining or 0) > 0 then
                local stop_age = now - (ctx._last_stop_send_time or 0)
                if stop_age < 0 or stop_age > 0.5 then
                    ctx._stop_redundancy_remaining = 0
                elseif stop_age >= 0.030 then
                    ctx._stop_redundancy_remaining = ctx._stop_redundancy_remaining - 1
                    ctx._last_stop_send_time = now
                    ctx._last_move_sent_time = now
                    if ctx._send_move_packet then
                        ctx._send_move_packet(0, 0)
                    end
                end
            end
        end
    end

    -- 3a. Flush queued delayed outbound packets (Symmetric Latency Simulator)
    if ctx._delayed_outbound_queue and #ctx._delayed_outbound_queue > 0 then
        local remaining_out = {}
        for _, delayed in ipairs(ctx._delayed_outbound_queue) do
            if now >= delayed.deliver_at then
                if ctx._udp and ctx._udp.send then
                    ctx._udp:send(delayed.data)
                end
            else
                table.insert(remaining_out, delayed)
            end
        end
        ctx._delayed_outbound_queue = remaining_out
    end

    -- 3b. Process queued delayed inbound packets (Synthetic Latency Simulator)
    if ctx._delayed_packet_queue and #ctx._delayed_packet_queue > 0 then
        local remaining = {}
        for _, delayed in ipairs(ctx._delayed_packet_queue) do
            if now >= delayed.deliver_at then
                on_dispatch_packet(delayed.data)
            else
                table.insert(remaining, delayed)
            end
        end
        ctx._delayed_packet_queue = remaining
    end

    -- 4. Receive non-blocking UDP datagrams
    while true do
        local data, err = ctx._udp:receive(65536)
        if not data then
            break
        end

        ctx._last_packet_received_time = now

        -- Synthetic Packet Loss Simulator
        local loss_rate = (ctx.netcode and ctx.netcode.simulate_packet_loss) or 0.0
        if loss_rate > 0 and math.random() < loss_rate then
            -- Intentionally dropped
        else
            local sim_latency = (ctx.netcode and ctx.netcode.simulate_latency) or 0.0
            if sim_latency > 0 then
                if not ctx._delayed_packet_queue then
                    ctx._delayed_packet_queue = {}
                end
                table.insert(ctx._delayed_packet_queue, {
                    deliver_at = now + sim_latency,
                    data = data
                })
            else
                on_dispatch_packet(data)
            end
        end
    end
end

return transport_module
