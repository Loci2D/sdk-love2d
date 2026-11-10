-- ============================================================================
-- Loci2D - Love2D Client SDK ('loci' root entry point)
-- Delegates to loci/init.lua to support environments without ?/init.lua in package.path.
-- ============================================================================

local current_module = ... or "loci"
local prefix = current_module:match("^(.-)loci$") or ""

local ok, loci = pcall(require, prefix .. "loci.init")
if ok then
    return loci
end

error("Could not load loci package. Details:\n" .. tostring(loci))
