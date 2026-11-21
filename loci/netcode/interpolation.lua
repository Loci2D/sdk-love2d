-- ============================================================================
-- Loci2D - Remote Entity Snapshot Interpolation Module (ADR 0001)
-- Interpolates remote entity transforms between past authoritative snapshots.
-- ============================================================================

local interpolation_module = {}

local function extrapolate_from_snapshot(entity, snap_ent, dt, tick_rate)
    entity.x = snap_ent.x + (snap_ent.vx or 0) * tick_rate * dt
    entity.y = snap_ent.y + (snap_ent.vy or 0) * tick_rate * dt
    entity.vx = snap_ent.vx or 0
    entity.vy = snap_ent.vy or 0
end

function interpolation_module.interpolate_remote_entity(entity, buffer, render_time, tick_rate, snap_threshold, now)
    buffer = buffer or {}
    local buf_len = #buffer
    snap_threshold = snap_threshold or 50.0
    local is_projectile = (entity.entity_type == "projectile")

    -- Short-lived fast projectiles skip the 50ms interpolation lag and advance
    -- continuously from the newest authoritative snapshot to avoid initial freeze
    -- or backward snapping when a second snapshot arrives.
    if is_projectile and now ~= nil and buf_len >= 1 then
        local newest = buffer[buf_len]
        local p_new = newest.entities[entity.id]
        if p_new then
            local elapsed = math.max(0.0, math.min(0.100, now - newest.receive_time))
            extrapolate_from_snapshot(entity, p_new, elapsed, tick_rate)
            return
        end
    end

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

                if (not is_projectile) and (dx * dx + dy * dy) > (snap_threshold * snap_threshold) then
                    -- Hard teleport / rubberband: snap immediately instead of sliding across map
                    if alpha >= 0.5 then
                        extrapolate_from_snapshot(entity, p2, 0.0, tick_rate)
                    else
                        extrapolate_from_snapshot(entity, p1, 0.0, tick_rate)
                    end
                else
                    entity.x = p1.x + dx * alpha
                    entity.y = p1.y + dy * alpha
                    entity.vx = (p1.vx or 0) + ((p2.vx or 0) - (p1.vx or 0)) * alpha
                    entity.vy = (p1.vy or 0) + ((p2.vy or 0) - (p1.vy or 0)) * alpha
                end
            elseif p2 then
                extrapolate_from_snapshot(entity, p2, 0.0, tick_rate)
            elseif p1 then
                extrapolate_from_snapshot(entity, p1, 0.0, tick_rate)
            else
                local newest = buffer[buf_len]
                local p_new = newest.entities[entity.id]
                if p_new then
                    local elapsed = (now ~= nil) and math.max(0.0, math.min(0.100, now - newest.receive_time)) or 0.0
                    extrapolate_from_snapshot(entity, p_new, elapsed, tick_rate)
                end
            end
        elseif render_time > buffer[buf_len].receive_time then
            -- Packet starvation / jitter: extrapolate slightly (up to 100ms) from newest snapshot
            local newest = buffer[buf_len]
            local p_new = newest.entities[entity.id]
            if p_new then
                local overdue = render_time - newest.receive_time
                local dt = (overdue <= 0.100) and overdue or 0.0
                extrapolate_from_snapshot(entity, p_new, dt, tick_rate)
            end
        elseif render_time < buffer[1].receive_time then
            -- Render time is before oldest buffered state
            local oldest = buffer[1]
            local p_old = oldest.entities[entity.id]
            if p_old then
                extrapolate_from_snapshot(entity, p_old, 0.0, tick_rate)
            end
        end
    elseif buf_len == 1 then
        local p = buffer[1].entities[entity.id]
        if p then
            extrapolate_from_snapshot(entity, p, 0.0, tick_rate)
        end
    else
        -- Fallback if no snapshots yet
        if entity.server_x and entity.server_y then
            entity.x = entity.server_x
            entity.y = entity.server_y
        end
    end
end

return interpolation_module
