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

local function apply_static_mtv(entity, nx, ny, penetration)
    if penetration <= 0 then return end
    entity.x = entity.x + nx * penetration
    entity.y = entity.y + ny * penetration

    local vx = entity.vx or 0
    local vy = entity.vy or 0
    local dot = vx * nx + vy * ny
    if dot < 0 then
        entity.vx = vx - nx * dot
        entity.vy = vy - ny * dot
    end
end

local function resolve_single_obstacle(entity, obs, radius)
    if not obs or not obs.is_solid then return end

    if obs.shape == "circle" then
        local dx = entity.x - (obs.x or 0)
        local dy = entity.y - (obs.y or 0)
        local sum_r = radius + (obs.radius or 0)
        local dist2 = dx * dx + dy * dy
        if dist2 < (sum_r * sum_r) then
            if dist2 > 1e-12 then
                local dist = math.sqrt(dist2)
                apply_static_mtv(entity, dx / dist, dy / dist, sum_r - dist)
            else
                apply_static_mtv(entity, 1.0, 0.0, sum_r)
            end
        end
        return
    end

    local hw = (obs.width or 0) * 0.5
    local hh = (obs.height or 0) * 0.5
    local ox = obs.x or 0
    local oy = obs.y or 0
    local min_x, max_x = ox - hw, ox + hw
    local min_y, max_y = oy - hh, oy + hh

    local px = math.max(min_x, math.min(entity.x, max_x))
    local py = math.max(min_y, math.min(entity.y, max_y))

    if px ~= entity.x or py ~= entity.y then
        local dx = entity.x - px
        local dy = entity.y - py
        local dist2 = dx * dx + dy * dy
        if dist2 < (radius * radius) then
            local dist = math.sqrt(dist2)
            if dist > 1e-12 then
                apply_static_mtv(entity, dx / dist, dy / dist, radius - dist)
            else
                apply_static_mtv(entity, 1.0, 0.0, radius)
            end
        end
    else
        local dist_left = entity.x - min_x
        local dist_right = max_x - entity.x
        local dist_bottom = entity.y - min_y
        local dist_top = max_y - entity.y

        local min_dist = dist_right
        local nx, ny = 1.0, 0.0
        if dist_left < min_dist then
            min_dist = dist_left
            nx, ny = -1.0, 0.0
        end
        if dist_top < min_dist then
            min_dist = dist_top
            nx, ny = 0.0, 1.0
        end
        if dist_bottom < min_dist then
            min_dist = dist_bottom
            nx, ny = 0.0, -1.0
        end
        apply_static_mtv(entity, nx, ny, radius + min_dist)
    end
end

function prediction_module.resolve_obstacle_collisions(entity, obstacles, entity_radius)
    if not entity or not obstacles then return end
    local radius = entity_radius or (entity.get and tonumber(entity:get("radius"))) or 2.0
    if radius <= 0 then return end

    if #obstacles > 0 then
        for _, obs in ipairs(obstacles) do
            resolve_single_obstacle(entity, obs, radius)
        end
    else
        for _, obs in pairs(obstacles) do
            resolve_single_obstacle(entity, obs, radius)
        end
    end
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

    local collide_obstacles = not (ctx.netcode and ctx.netcode.obstacle_collision_prediction == false)
    if collide_obstacles and not incapacitated and not prediction_starved and ctx.obstacles and next(ctx.obstacles) ~= nil then
        local list = ctx.get_obstacles and ctx.get_obstacles() or ctx.obstacles
        local default_radius = (ctx.netcode and ctx.netcode.default_entity_radius) or 2.0
        local radius = (entity.get and tonumber(entity:get("radius"))) or default_radius
        prediction_module.resolve_obstacle_collisions(entity, list, radius)
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
