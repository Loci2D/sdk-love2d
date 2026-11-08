-- ============================================================================
-- Loci2D - Protobuf & Schema Loader Module
-- Multi-path probing for game_packets.proto / .pb with dynamic fallback.
-- ============================================================================

local schema_module = {}

local pb = nil
local protoc = nil
local schema_loaded = false

-- Discover directories of current script and SDK root to locate adjacent 'lib/' folder
local script_dir = ""
local sdk_root = ""
local info = debug.getinfo(1, "S")
if info and info.source and info.source:sub(1, 1) == "@" then
    local src_path = info.source:sub(2)
    script_dir = src_path:match("^(.*[/\\])") or ""
    sdk_root = src_path:match("^(.-)loci[/\\]") or script_dir
end

local cpath_candidates = {
    sdk_root .. "lib/?.so",
    sdk_root .. "lib/?.dylib",
    sdk_root .. "lib/?.dll",
    sdk_root .. "?.so",
    sdk_root .. "?.dylib",
    sdk_root .. "?.dll",
    script_dir .. "lib/?.so",
    script_dir .. "lib/?.dylib",
    script_dir .. "lib/?.dll",
    script_dir .. "../../lib/?.so",
    script_dir .. "../../lib/?.dylib",
    script_dir .. "../../lib/?.dll",
    "./?.so", "./lib/?.so", "./loci2d/lib/?.so", "./client/loci2d/lib/?.so",
    "./?.dylib", "./lib/?.dylib", "./loci2d/lib/?.dylib", "./client/loci2d/lib/?.dylib",
    "./?.dll", "./lib/?.dll", "./loci2d/lib/?.dll", "./client/loci2d/lib/?.dll",
    "sdks/love2d/lib/?.so", "../../sdks/love2d/lib/?.so"
}
for _, pat in ipairs(cpath_candidates) do
    if not package.cpath:find(pat, 1, true) then
        package.cpath = package.cpath .. ";" .. pat
    end
end

local path_candidates = {
    sdk_root .. "lib/?.lua",
    sdk_root .. "?.lua",
    script_dir .. "lib/?.lua",
    script_dir .. "../../lib/?.lua",
    "./?.lua", "./lib/?.lua", "./loci2d/lib/?.lua", "./client/loci2d/lib/?.lua",
    "./loci2d/?.lua", "./client/loci2d/?.lua",
    "sdks/love2d/lib/?.lua", "../../sdks/love2d/lib/?.lua"
}
for _, pat in ipairs(path_candidates) do
    if not package.path:find(pat, 1, true) then
        package.path = package.path .. ";" .. pat
    end
end

-- Attempt to load lua-protobuf library and protoc parser
local ok_pb, res_pb = pcall(require, "pb")
if ok_pb then
    pb = res_pb
    local ok_protoc, res_protoc = pcall(require, "protoc")
    if ok_protoc then
        protoc = res_protoc
    end
else
    print("[Warning] 'lua-protobuf' module not found.")
    print("Install lua-protobuf (e.g. via luarocks install lua-protobuf) to run full binary Protobuf encoding.")
end

local function read_proto_file(path)
    if not path then return nil end
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and #content > 0 then return content end
    end
    if love and love.filesystem and love.filesystem.getInfo and love.filesystem.getInfo(path) then
        local content, _ = love.filesystem.read(path)
        if content and #content > 0 then return content end
    end
    return nil
end

function schema_module.load(base_path)
    if not pb then
        schema_loaded = false
        return false, nil, nil
    end

    local candidate_proto_paths = {
        base_path and (base_path .. "game_packets.proto"),
        base_path and (base_path .. "/game_packets.proto"),
        sdk_root ~= "" and (sdk_root .. "lib/game_packets.proto") or nil,
        sdk_root ~= "" and (sdk_root .. "game_packets.proto") or nil,
        script_dir ~= "" and (script_dir .. "lib/game_packets.proto") or nil,
        script_dir ~= "" and (script_dir .. "../../lib/game_packets.proto") or nil,
        "lib/game_packets.proto",
        "loci2d/lib/game_packets.proto",
        "client/loci2d/lib/game_packets.proto",
        "sdks/love2d/lib/game_packets.proto",
        "../../sdks/love2d/lib/game_packets.proto",
        "proto/game_packets.proto",
        "../../proto/game_packets.proto",
        "game_packets.proto",
    }

    schema_loaded = false

    -- 1. Try dynamic text parsing with protoc.lua
    if protoc then
        local p = protoc.new()
        p.include_dirs = {
            base_path,
            sdk_root .. "lib",
            script_dir .. "lib",
            script_dir .. "../../lib",
            "lib",
            "loci2d/lib",
            "client/loci2d/lib",
            "sdks/love2d/lib",
            "proto",
            "../../proto",
            "."
        }

        for _, path in ipairs(candidate_proto_paths) do
            local content = read_proto_file(path)
            if content then
                local ok, _ = pcall(function() return p:load(content, "game_packets.proto") end)
                if ok then
                    schema_loaded = true
                    break
                end
            end
        end
    end

    -- 2. Fallback: try loading compiled .pb descriptor file
    if not schema_loaded then
        local candidate_pb_paths = {
            base_path and (base_path .. "game_packets.pb"),
            base_path and (base_path .. "/game_packets.pb"),
            sdk_root ~= "" and (sdk_root .. "lib/game_packets.pb") or nil,
            sdk_root ~= "" and (sdk_root .. "game_packets.pb") or nil,
            script_dir ~= "" and (script_dir .. "lib/game_packets.pb") or nil,
            script_dir ~= "" and (script_dir .. "../../lib/game_packets.pb") or nil,
            "lib/game_packets.pb",
            "loci2d/lib/game_packets.pb",
            "client/loci2d/lib/game_packets.pb",
            "sdks/love2d/lib/game_packets.pb",
            "../../sdks/love2d/lib/game_packets.pb",
            "game_packets.pb",
        }
        for _, path in ipairs(candidate_pb_paths) do
            local ok, res = pcall(function() return pb.loadfile(path) end)
            if ok and res then
                schema_loaded = true
                break
            end
        end
    end

    return schema_loaded, pb, protoc
end

function schema_module.get_pb()
    return pb
end

function schema_module.get_protoc()
    return protoc
end

function schema_module.is_loaded()
    return schema_loaded
end

function schema_module.set_loaded(loaded)
    schema_loaded = loaded
end

return schema_module
