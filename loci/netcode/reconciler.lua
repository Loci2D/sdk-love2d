-- ============================================================================
-- Loci2D - Reconciliation & Error Smoothing Module (ADR 0001)
-- Authoritative server position reconciliation and exponential error decay.
-- ============================================================================

local reconciler_module = {}

function reconciler_module.reconcile_position(entity, nx, ny, snap_threshold, rec_threshold)
    snap_threshold = snap_threshold or 50.0
    rec_threshold = rec_threshold or 2.0

    local err_x = nx - entity.x
    local err_y = ny - entity.y
    local dist2 = err_x * err_x + err_y * err_y

    if dist2 > (snap_threshold * snap_threshold) then
        -- Critical divergence (teleport, respawn, hard knockback): hard snap
        entity.x = nx
        entity.y = ny
        entity._error_x = 0
        entity._error_y = 0
    elseif dist2 > (rec_threshold * rec_threshold) then
        -- Moderate divergence: store error offset for exponential decay smoothing
        entity._error_x = err_x
        entity._error_y = err_y
    else
        -- Negligible divergence (< 2px): suppress micro-jitter
        entity._error_x = 0
        entity._error_y = 0
    end
end

function reconciler_module.decay_error(entity, dt, decay_rate)
    if not ((entity._error_x and entity._error_x ~= 0) or (entity._error_y and entity._error_y ~= 0)) then
        return
    end

    decay_rate = decay_rate or 15.0
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

return reconciler_module
