-- ============================================================================
-- Loci2D - Telemetry CSV Exporter Module
-- Formats and writes chronological network performance logs to disk.
-- ============================================================================

local exporter_module = {}

function exporter_module.export_csv(stats, filepath)
    if not stats then return nil, "No telemetry stats available" end

    if not filepath or filepath == "" then
        local ts = os.date("%Y%m%d_%H%M%S")
        filepath = "logs/network_stats_" .. tostring(ts) .. ".csv"
    end

    -- Ensure directory exists cross-platform
    pcall(function()
        if love and love.filesystem and love.filesystem.createDirectory then
            love.filesystem.createDirectory("logs")
        elseif os.execute then
            os.execute("mkdir -p logs 2>/dev/null")
        end
    end)

    local file, err = io.open(filepath, "w")
    if not file then
        if love and love.filesystem and love.filesystem.write then
            local lines = { "client_time_ms,server_tick,rtt_ms,jitter_ms,delta_snapshot_ms,loss_pct,fps\n" }
            local start_idx = (stats.csv_count == stats.max_csv_rows) and stats.csv_index or 1
            for i = 0, stats.csv_count - 1 do
                local idx = ((start_idx - 1 + i) % stats.max_csv_rows) + 1
                local row = stats.csv_rows[idx]
                table.insert(lines, string.format(
                    "%d,%d,%.2f,%.2f,%.2f,%.2f,%.1f\n",
                    row.client_time_ms,
                    row.server_tick,
                    row.rtt_ms,
                    row.jitter_ms,
                    row.delta_snapshot_ms,
                    row.loss_pct,
                    row.fps
                ))
            end
            local ok, werr = love.filesystem.write(filepath, table.concat(lines))
            if ok then
                return filepath, stats.csv_count
            end
        end
        return nil, "Could not open file for writing: " .. tostring(err)
    end

    -- Header according to technical specification
    file:write("client_time_ms,server_tick,rtt_ms,jitter_ms,delta_snapshot_ms,loss_pct,fps\n")

    -- Write recorded rows chronologically
    local start_idx = 1
    if stats.csv_count == stats.max_csv_rows then
        start_idx = stats.csv_index
    end

    for i = 0, stats.csv_count - 1 do
        local idx = ((start_idx - 1 + i) % stats.max_csv_rows) + 1
        local row = stats.csv_rows[idx]
        file:write(string.format(
            "%d,%d,%.2f,%.2f,%.2f,%.2f,%.1f\n",
            row.client_time_ms,
            row.server_tick,
            row.rtt_ms,
            row.jitter_ms,
            row.delta_snapshot_ms,
            row.loss_pct,
            row.fps
        ))
    end

    file:close()
    return filepath, stats.csv_count
end

return exporter_module
