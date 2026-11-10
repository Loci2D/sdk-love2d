-- ============================================================================
-- Loci2D - Client-Side Prediction Module (ADR 0001 & ADR 0002)
-- Local avatar kinematic prediction, status-effect gating, and horizon cap.
-- ============================================================================

local prediction_module = {}

function prediction_module.update_immediate_velocity(entity, dx, dy, default_move_speed)
    if not entity then return end
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 0 then
        local move_speed = tonumber(entity:get("move_speed") or entity:get("speed") or default_move_speed) or 3.0
        entity.vx = (dx / len) * move_speed
        entity.vy = (dy / len) * move_speed
    else
        entity.vx = 0
        entity.vy = 0
    end
end

function prediction_module.is_prediction_starved(last_state_received_time, now, timeout)
    if last_state_received_time == nil then return false end
    timeout = timeout or 0.500
    return (now - last_state_received_time) > timeout
end

function prediction_module.is_incapacitated(entity, cur_tick)
    if not entity then return false end
    cur_tick = cur_tick or 0
    local is_dead_prop = entity:get("is_dead")
    local is_dead = (is_dead_prop == "true" or is_dead_prop == true or is_dead_prop == 1 or is_dead_prop == "1")
    if is_dead then return true end
    local stunned_until = tonumber(entity:get("stunned_until")) or 0
    local paralyzed_until = tonumber(entity:get("paralyzed_until")) or 0
    return (cur_tick < stunned_until) or (cur_tick < paralyzed_until)
end

function prediction_module.predict_local_player(entity, ctx, dt, tick_rate, prediction_starved)
    local cur_tick = ctx._last_state_tick or 0
    local dashing_until = tonumber(entity:get("dashing_until")) or 0
    local incapacitated = prediction_module.is_incapacitated(entity, cur_tick)

    if incapacitated or prediction_starved then
        entity.vx = 0
        entity.vy = 0
    elseif cur_tick < dashing_until then
        -- Dash active: let server physical velocity guide displacement
        local vx_sec = (entity.vx or 0) * tick_rate
        local vy_sec = (entity.vy or 0) * tick_rate
        entity.x = entity.x + vx_sec * dt
        entity.y = entity.y + vy_sec * dt
    elseif ctx._prediction_handler then
        -- Pluggable prediction hook for custom physics
        ctx._prediction_handler(entity, ctx._active_move_dx or 0, ctx._active_move_dy or 0, dt)
    else
        -- Default Kinematic Prediction
        local in_dx = ctx._active_move_dx or 0
        local in_dy = ctx._active_move_dy or 0
        local len = math.sqrt(in_dx * in_dx + in_dy * in_dy)

        if len > 0 then
            local ndx = in_dx / len
            local ndy = in_dy / len
            local default_speed = (ctx.netcode and ctx.netcode.default_move_speed) or 3.0
            local move_speed = tonumber(entity:get("move_speed") or entity:get("speed") or default_speed) or 3.0
            local speed_sec = move_speed * tick_rate

            entity.x = entity.x + ndx * speed_sec * dt
            entity.y = entity.y + ndy * speed_sec * dt
            entity.vx = ndx * move_speed
            entity.vy = ndy * move_speed
        else
            if not ctx._active_move_cleared_by_timeout then
                entity.vx = 0
                entity.vy = 0
            end
        end
    end
end

function prediction_module.lerp_server_fallback(entity, dt, tick_rate, snap_threshold, prediction_starved)
    if prediction_starved then
        entity.vx = 0
        entity.vy = 0
        return
    end

    local vx_sec = (entity.vx or 0) * tick_rate
    local vy_sec = (entity.vy or 0) * tick_rate

    if entity.server_x and entity.server_y then
        entity.server_x = entity.server_x + vx_sec * dt
        entity.server_y = entity.server_y + vy_sec * dt

        local dx = entity.server_x - entity.x
        local dy = entity.server_y - entity.y
        local dist2 = dx * dx + dy * dy
        local snap_thresh = snap_threshold or 50.0

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

return prediction_module
