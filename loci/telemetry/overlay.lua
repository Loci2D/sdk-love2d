-- ============================================================================
-- Loci2D - Telemetry Debug HUD Overlay Module
-- Renders real-time network telemetry diagnostics (F3) in love.graphics.
-- ============================================================================

local overlay_module = {}

function overlay_module.draw_overlay(network_stats, show_debug_overlay, x, y)
    if not show_debug_overlay then return end
    if not love or not love.graphics then return end

    x = x or 10
    y = y or 10
    local stats_str = network_stats and network_stats:get_summary_string() or "[REDE] Telemetria inativa"

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

return overlay_module
