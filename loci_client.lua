-- ============================================================================
-- Loci2D - Love2D Client SDK (Backward-Compatibility Shim)
-- Delegates to modular 'loci' package while preserving legacy require paths.
-- ============================================================================

local current_module = ... or "loci_client"
local prefix = current_module:match("^(.-)loci_client$") or ""

local ok, loci = pcall(require, prefix .. "loci")
if not ok then
    ok, loci = pcall(require, prefix .. "loci.init")
    if not ok then
        error("Could not load loci package. Details:\n" .. tostring(loci))
    end
end

return loci
