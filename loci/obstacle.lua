-- ============================================================================
-- Loci2D - Static Obstacle & Trigger Zone Module
-- Defines Obstacle metatable, snapshot normalization, and spatial queries.
-- ============================================================================

local modname = ... or "loci.obstacle"
local prefix = (modname:match("^(.-)obstacle$") or "loci."):gsub("%.+$", ".")
local entity_mod = require(prefix .. "entity")

local obstacle_module = {}

local loci_ctx = nil

function obstacle_module.bind_context(ctx)
    loci_ctx = ctx
end

function obstacle_module.normalize_shape(raw_shape)
    if raw_shape == 1 or raw_shape == "OBSTACLE_CIRCLE" or raw_shape == "circle" then
        return "circle"
    end
    return "aabb"
end

-- ============================================================================
-- High-Level Obstacle Abstraction
-- ============================================================================
local Obstacle = {}
Obstacle.__index = function(t, k)
    local method = Obstacle[k]
    if method ~= nil then return method end
    local props = rawget(t, "properties")
    if props ~= nil then
        return props[k]
    end
    return nil
end

function Obstacle:get(prop_name, default_value)
    local props = rawget(self, "properties")
    if props and props[prop_name] ~= nil then
        return props[prop_name]
    end
    return default_value
end

function Obstacle:bounds()
    if self.shape == "circle" then
        local r = self.radius or 0
        return self.x - r, self.y - r, self.x + r, self.y + r
    end
    local hw = (self.width or 0) * 0.5
    local hh = (self.height or 0) * 0.5
    return self.x - hw, self.y - hh, self.x + hw, self.y + hh
end

function Obstacle:contains_point(px, py)
    if self.shape == "circle" then
        local dx = px - self.x
        local dy = py - self.y
        local r = self.radius or 0
        return (dx * dx + dy * dy) <= (r * r)
    end
    local min_x, min_y, max_x, max_y = self:bounds()
    return px >= min_x and px <= max_x and py >= min_y and py <= max_y
end

function Obstacle:intersects_circle(cx, cy, radius)
    local r = radius or 0
    if self.shape == "circle" then
        local dx = cx - self.x
        local dy = cy - self.y
        local sum_r = (self.radius or 0) + r
        return (dx * dx + dy * dy) <= (sum_r * sum_r)
    end
    local min_x, min_y, max_x, max_y = self:bounds()
    local px = math.max(min_x, math.min(cx, max_x))
    local py = math.max(min_y, math.min(cy, max_y))
    local dx = cx - px
    local dy = cy - py
    return (dx * dx + dy * dy) <= (r * r)
end

function Obstacle:distance_to(other_or_pos)
    if not other_or_pos then return 0 end
    local ox = other_or_pos.x or 0
    local oy = other_or_pos.y or 0
    local dx = self.x - ox
    local dy = self.y - oy
    return math.sqrt(dx * dx + dy * dy)
end

obstacle_module.Obstacle = Obstacle

function obstacle_module.new_obstacle(id, blueprint)
    local obs = {
        id = id,
        blueprint = blueprint or "wall",
        shape = "aabb",
        x = 0,
        y = 0,
        width = 0,
        height = 0,
        radius = 0,
        is_solid = true,
        collision_type = "solid",
        properties = {}
    }
    setmetatable(obs, Obstacle)
    return obs
end

function obstacle_module.apply_snapshot(obs, raw_obs)
    obs.blueprint = (raw_obs.blueprint and raw_obs.blueprint ~= "") and raw_obs.blueprint or obs.blueprint or "wall"
    obs.shape = obstacle_module.normalize_shape(raw_obs.shape)
    obs.is_solid = (raw_obs.is_solid == true)

    if raw_obs.collision_type and raw_obs.collision_type ~= "" then
        obs.collision_type = raw_obs.collision_type
    else
        obs.collision_type = obs.is_solid and "solid" or "trigger"
    end

    if raw_obs.position then
        obs.x = entity_mod.bits_to_float(raw_obs.position.x_bits)
        obs.y = entity_mod.bits_to_float(raw_obs.position.y_bits)
    else
        obs.x = obs.x or 0
        obs.y = obs.y or 0
    end

    if obs.shape == "circle" then
        obs.radius = entity_mod.bits_to_float(raw_obs.radius_bits)
        obs.width = 0
        obs.height = 0
    else
        obs.width = entity_mod.bits_to_float(raw_obs.width_bits)
        obs.height = entity_mod.bits_to_float(raw_obs.height_bits)
        obs.radius = 0
    end
end

local function ensure_sorted_cache(ctx)
    if not ctx._obstacles_list_cache then
        local list = {}
        for _, obs in pairs(ctx.obstacles or {}) do
            table.insert(list, obs)
        end
        table.sort(list, function(a, b) return a.id < b.id end)
        ctx._obstacles_list_cache = list
    end
    return ctx._obstacles_list_cache
end

-- Cached and sorted by id ascending; returns a pooled shallow copy to prevent internal cache mutation
function obstacle_module.get_obstacles(ctx)
    ctx = ctx or loci_ctx
    if not ctx then return {} end

    local cache = ensure_sorted_cache(ctx)

    if not ctx._public_obstacles_list then
        ctx._public_obstacles_list = {}
    end

    local public_list = ctx._public_obstacles_list
    for i = 1, #public_list do
        public_list[i] = nil
    end
    for i = 1, #cache do
        public_list[i] = cache[i]
    end

    return public_list
end

function obstacle_module.get_obstacle(ctx, id)
    ctx = ctx or loci_ctx
    if not ctx or not ctx.obstacles then return nil end
    return ctx.obstacles[id]
end

function obstacle_module.get_obstacles_by_blueprint(ctx, blueprint_name)
    ctx = ctx or loci_ctx
    if not ctx then return {} end
    local list = {}
    for _, obs in ipairs(ensure_sorted_cache(ctx)) do
        if obs.blueprint == blueprint_name then
            table.insert(list, obs)
        end
    end
    return list
end

function obstacle_module.get_solid_obstacles(ctx)
    ctx = ctx or loci_ctx
    if not ctx then return {} end
    local list = {}
    for _, obs in ipairs(ensure_sorted_cache(ctx)) do
        if obs.is_solid then
            table.insert(list, obs)
        end
    end
    return list
end

function obstacle_module.get_obstacles_in_radius(ctx, center_x, center_y, radius)
    ctx = ctx or loci_ctx
    if not ctx then return {} end
    local list = {}
    for _, obs in ipairs(ensure_sorted_cache(ctx)) do
        if obs:intersects_circle(center_x, center_y, radius) then
            table.insert(list, obs)
        end
    end
    return list
end

return obstacle_module
