-- ============================================================================
-- Loci2D - Remote Entity Snapshot Interpolation Module (ADR 0001)
-- Interpolates remote entity transforms between past authoritative snapshots.
-- ============================================================================

local interpolation_module = {}

function interpolation_module.interpolate_remote_entity(entity, buffer, render_time, tick_rate, snap_threshold)
    buffer = buffer or {}
    local buf_len = #buffer
    snap_threshold = snap_threshold or 50.0

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

                if (dx * dx + dy * dy) > (snap_threshold * snap_threshold) then
                    -- Hard teleport / rubberband: snap immediately instead of sliding across map
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

return interpolation_module
