-- ============================================================================
-- Loci2D - Snapshot Buffer Module
-- Circular buffer recording authoritative world snapshots for interpolation.
-- ============================================================================

local buffer_module = {}

function buffer_module.record_snapshot(snapshot_buffer, tick, receive_time, entities, max_history)
    max_history = max_history or 20
    local snap_entities = {}
    for id, ent in pairs(entities) do
        snap_entities[id] = {
            x = ent.server_x or ent.x or 0,
            y = ent.server_y or ent.y or 0,
            vx = ent.vx or 0,
            vy = ent.vy or 0
        }
    end

    table.insert(snapshot_buffer, {
        tick = tick or 0,
        receive_time = receive_time,
        entities = snap_entities
    })

    while #snapshot_buffer > max_history do
        table.remove(snapshot_buffer, 1)
    end
end

function buffer_module.clear(snapshot_buffer)
    for i = 1, #snapshot_buffer do
        snapshot_buffer[i] = nil
    end
end

return buffer_module
