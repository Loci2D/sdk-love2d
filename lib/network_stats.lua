-- ============================================================================
-- NetworkStats: Zero-GC Real-time Network Telemetry & Packet Analysis
-- RFC 3550 EWMA Jitter, RTT Tracking, Tick Delta, and Loss % Calculation
-- ============================================================================

local CircularBuffer = {}
CircularBuffer.__index = CircularBuffer

function CircularBuffer.new(capacity)
    local self = setmetatable({}, CircularBuffer)
    self.capacity = capacity or 120
    self.data = {}
    for i = 1, self.capacity do
        self.data[i] = 0
    end
    self.index = 1
    self.count = 0
    return self
end

function CircularBuffer:push(val)
    self.data[self.index] = tonumber(val) or 0
    self.index = (self.index % self.capacity) + 1
    if self.count < self.capacity then
        self.count = self.count + 1
    end
end

function CircularBuffer:get_stats()
    if self.count == 0 then
        return 0, 0, 0
    end
    local sum = 0
    local min_val = self.data[1]
    local max_val = self.data[1]
    for i = 1, self.count do
        local v = self.data[i]
        sum = sum + v
        if v < min_val then min_val = v end
        if v > max_val then max_val = v end
    end
    local avg = sum / self.count
    return avg, min_val, max_val
end

function CircularBuffer:clear()
    for i = 1, self.capacity do
        self.data[i] = 0
    end
    self.index = 1
    self.count = 0
end

-- ============================================================================
-- NetworkStats Manager
-- ============================================================================
local NetworkStats = {}
NetworkStats.__index = NetworkStats
NetworkStats.CircularBuffer = CircularBuffer

function NetworkStats.new(opts)
    opts = opts or {}
    local self = setmetatable({}, NetworkStats)

    local capacity = opts.capacity or 120
    self.capacity = capacity
    self.rtt_buffer = CircularBuffer.new(capacity)
    self.delta_snapshot_buffer = CircularBuffer.new(capacity)

    -- RTT metrics (ms)
    self.rtt = 0
    self.rtt_avg = 0
    self.rtt_min = 0
    self.rtt_max = 0

    -- Jitter RFC 3550 (EWMA filter with alpha = 1/16 = 0.0625)
    self.jitter = 0
    self.last_rtt = nil

    -- Snapshot & Frequency metrics
    self.last_snapshot_time = nil
    self.delta_snapshot_ms = 0
    self.tick_hz = 0

    -- Packet Loss & Reordering metrics (evaluated from server_tick)
    self.last_server_tick = nil
    self.total_packets_received = 0
    self.total_packets_expected = 0
    self.out_of_order_count = 0
    self.loss_pct = 0.0

    -- Static pre-allocated pool for CSV telemetry rows (Zero GC during match)
    self.max_csv_rows = opts.max_csv_rows or 7200 -- Default ~2-4 minutes of snapshots at 30-60Hz
    self.csv_rows = {}
    for i = 1, self.max_csv_rows do
        self.csv_rows[i] = {
            client_time_ms = 0,
            server_tick = 0,
            rtt_ms = 0,
            jitter_ms = 0,
            delta_snapshot_ms = 0,
            loss_pct = 0,
            fps = 0
        }
    end
    self.csv_index = 1
    self.csv_count = 0

    return self
end

function NetworkStats:record_rtt(rtt_ms)
    rtt_ms = math.max(0, tonumber(rtt_ms) or 0)
    self.rtt = rtt_ms
    self.rtt_buffer:push(rtt_ms)
    self.rtt_avg, self.rtt_min, self.rtt_max = self.rtt_buffer:get_stats()

    -- RFC 3550 EWMA Jitter Formula:
    -- D_i = |RTT_i - RTT_{i-1}|
    -- J_i = J_{i-1} + (D_i - J_{i-1}) / 16
    if self.last_rtt ~= nil then
        local d = math.abs(rtt_ms - self.last_rtt)
        self.jitter = self.jitter + (d - self.jitter) / 16.0
    else
        self.jitter = 0.0
    end
    self.last_rtt = rtt_ms
end

function NetworkStats:record_snapshot(server_tick, client_time_sec)
    client_time_sec = client_time_sec or (os.clock and os.clock() or 0)

    -- 1. Delta snapshot arrival and received frequency (Hz)
    if self.last_snapshot_time ~= nil then
        local dt_ms = (client_time_sec - self.last_snapshot_time) * 1000.0
        if dt_ms > 0 then
            self.delta_snapshot_ms = dt_ms
            self.delta_snapshot_buffer:push(dt_ms)
            local avg_dt, _, _ = self.delta_snapshot_buffer:get_stats()
            if avg_dt > 0 then
                self.tick_hz = 1000.0 / avg_dt
            else
                self.tick_hz = 1000.0 / dt_ms
            end
        end
    end
    self.last_snapshot_time = client_time_sec

    -- 2. Loss & Reorder evaluation from server_tick delta
    if server_tick and server_tick > 0 then
        if self.last_server_tick == nil then
            self.last_server_tick = server_tick
            self.total_packets_received = 1
            self.total_packets_expected = 1
            self.loss_pct = 0.0
        else
            local dtick = server_tick - self.last_server_tick
            if dtick > 0 then
                self.total_packets_received = self.total_packets_received + 1
                self.total_packets_expected = self.total_packets_expected + dtick
                self.last_server_tick = server_tick
            else
                -- dtick <= 0: Out-of-order or duplicate packet
                self.out_of_order_count = self.out_of_order_count + 1
            end

            if self.total_packets_expected > 0 then
                self.loss_pct = (1.0 - (self.total_packets_received / self.total_packets_expected)) * 100.0
                if self.loss_pct < 0 then self.loss_pct = 0.0 end
            end
        end
    end
end

function NetworkStats:record_telemetry_row(client_time_ms, server_tick, fps)
    local row = self.csv_rows[self.csv_index]
    if row then
        row.client_time_ms = client_time_ms or 0
        row.server_tick = server_tick or (self.last_server_tick or 0)
        row.rtt_ms = self.rtt
        row.jitter_ms = self.jitter
        row.delta_snapshot_ms = self.delta_snapshot_ms
        row.loss_pct = self.loss_pct
        row.fps = fps or 60.0

        self.csv_index = (self.csv_index % self.max_csv_rows) + 1
        if self.csv_count < self.max_csv_rows then
            self.csv_count = self.csv_count + 1
        end
    end
end

function NetworkStats:get_summary_string()
    return string.format(
        "[REDE] Ping: %.0fms (min: %.0f | max: %.0f) | Jitter: %.1fms | Loss: %.1f%% | Tick: %.1f Hz",
        self.rtt,
        self.rtt_min,
        self.rtt_max,
        self.jitter,
        self.loss_pct,
        self.tick_hz
    )
end

function NetworkStats:get_stats()
    return {
        rtt = self.rtt,
        rtt_avg = self.rtt_avg,
        rtt_min = self.rtt_min,
        rtt_max = self.rtt_max,
        jitter = self.jitter,
        loss_pct = self.loss_pct,
        tick_hz = self.tick_hz,
        delta_snapshot_ms = self.delta_snapshot_ms,
        total_packets_received = self.total_packets_received,
        total_packets_expected = self.total_packets_expected,
        out_of_order_count = self.out_of_order_count,
        last_server_tick = self.last_server_tick or 0
    }
end

function NetworkStats:export_csv(filepath)
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
            local start_idx = (self.csv_count == self.max_csv_rows) and self.csv_index or 1
            for i = 0, self.csv_count - 1 do
                local idx = ((start_idx - 1 + i) % self.max_csv_rows) + 1
                local row = self.csv_rows[idx]
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
                return filepath, self.csv_count
            end
        end
        return nil, "Could not open file for writing: " .. tostring(err)
    end

    -- Header according to technical specification
    file:write("client_time_ms,server_tick,rtt_ms,jitter_ms,delta_snapshot_ms,loss_pct,fps\n")

    -- Write recorded rows chronologically
    local start_idx = 1
    if self.csv_count == self.max_csv_rows then
        start_idx = self.csv_index
    end

    for i = 0, self.csv_count - 1 do
        local idx = ((start_idx - 1 + i) % self.max_csv_rows) + 1
        local row = self.csv_rows[idx]
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
    return filepath, self.csv_count
end

return NetworkStats
