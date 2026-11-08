-- ============================================================================
-- Loci2D - Entity Management & Property Casting Module
-- Defines Entity metatable, property casting, helpers, and spatial queries.
-- ============================================================================

local entity_module = {}

local loci_ctx = nil

function entity_module.bind_context(ctx)
    loci_ctx = ctx
end

function entity_module.bits_to_float(bits)
    if not bits then return 0.0 end
    return bits / 65536.0
end

function entity_module.float_to_bits(f)
    if not f then return 0 end
    return math.floor(f * 65536)
end

function entity_module.cast_property_value(val)
    if type(val) ~= "string" then return val end
    if val == "true" or val == "True" then return true end
    if val == "false" or val == "False" then return false end
    local num = tonumber(val)
    if num ~= nil then return num end
    return val
end

-- ============================================================================
-- High-Level Entity Abstraction
-- ============================================================================
local Entity = {}
Entity.__index = function(t, k)
    local method = Entity[k]
    if method ~= nil then return method end
    local props = rawget(t, "properties")
    if props ~= nil then
        return props[k]
    end
    return nil
end

function Entity:is_local_player()
    return loci_ctx ~= nil and self.id == loci_ctx.my_entity_id
end

function Entity:distance_to(other_or_pos)
    if not other_or_pos then return 0 end
    local ox = other_or_pos.x or 0
    local oy = other_or_pos.y or 0
    local dx = self.x - ox
    local dy = self.y - oy
    return math.sqrt(dx * dx + dy * dy)
end

function Entity:get(prop_name, default_value)
    local props = rawget(self, "properties")
    if props and props[prop_name] ~= nil then
        return props[prop_name]
    end
    return default_value
end

entity_module.Entity = Entity

function entity_module.new_entity(id, blueprint)
    local ent = {
        id = id,
        blueprint = blueprint,
        x = 0,
        y = 0,
        vx = 0,
        vy = 0,
        server_x = nil,
        server_y = nil,
        server_vx = 0,
        server_vy = 0,
        _error_x = 0,
        _error_y = 0,
        properties = {}
    }
    setmetatable(ent, Entity)
    return ent
end

-- Cached to avoid GC pressure, returns a pooled shallow copy to prevent internal cache mutation
function entity_module.get_entities(ctx)
    ctx = ctx or loci_ctx
    if not ctx then return {} end

    if not ctx._entities_list_cache then
        local list = {}
        for _, e in pairs(ctx.entities) do
            table.insert(list, e)
        end
        ctx._entities_list_cache = list
    end

    if not ctx._public_entities_list then
        ctx._public_entities_list = {}
    end

    local public_list = ctx._public_entities_list
    for i = 1, #public_list do
        public_list[i] = nil
    end
    for i = 1, #ctx._entities_list_cache do
        public_list[i] = ctx._entities_list_cache[i]
    end

    return public_list
end

function entity_module.get_entities_by_blueprint(ctx, blueprint_name)
    ctx = ctx or loci_ctx
    if not ctx then return {} end
    local list = {}
    for _, e in pairs(ctx.entities) do
        if e.blueprint == blueprint_name then
            table.insert(list, e)
        end
    end
    return list
end

function entity_module.get_entities_in_radius(ctx, center_x, center_y, radius)
    ctx = ctx or loci_ctx
    if not ctx then return {} end
    local list = {}
    local r2 = radius * radius
    for _, e in pairs(ctx.entities) do
        local dx = e.x - center_x
        local dy = e.y - center_y
        if (dx * dx + dy * dy) <= r2 then
            table.insert(list, e)
        end
    end
    return list
end

function entity_module.get_my_entity(ctx)
    ctx = ctx or loci_ctx
    if ctx and ctx.my_entity_id then
        return ctx.entities[ctx.my_entity_id]
    end
    return nil
end

function entity_module.get_globals(ctx)
    ctx = ctx or loci_ctx
    return ctx and ctx.globals or {}
end

return entity_module
