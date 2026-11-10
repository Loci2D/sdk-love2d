-- ============================================================================
-- NetworkStats: Backward-Compatibility Shim
-- Delegates to loci.telemetry.stats while preserving legacy require paths.
-- ============================================================================

local current_module = ... or "lib.network_stats"
local prefix = current_module:match("^(.-)lib%.network_stats$") or ""

local ok, stats = pcall(require, prefix .. "loci.telemetry.stats")
if not ok then
    ok, stats = pcall(require, "loci.telemetry.stats")
end

if ok and stats then
    return stats
end

error("Could not load loci.telemetry.stats module: " .. tostring(stats))
