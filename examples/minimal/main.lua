-- Minimal Love2D Example using Loci2D SDK
package.path = package.path .. ";../../?.lua;../../lib/?.lua;./?.lua;./lib/?.lua"
package.cpath = package.cpath .. ";../../lib/?.so;../../lib/?.dylib;../../lib/?.dll;./?.so;./lib/?.so"

local loci = require("loci_client")

local player_name = "Player_" .. tostring(love.math.random(100, 999))
local status_text = "Disconnected"

function love.load()
    -- Connect to local authoritative Loci2D server
    local ok = loci.connect("127.0.0.1", 8080, player_name)
    if ok then
        status_text = "Connected to 127.0.0.1:8080 as " .. player_name
    else
        status_text = "Connection failed"
    end

    loci.on_intent_rejected = function(reason)
        status_text = "Action Rejected: " .. tostring(reason)
    end
end

function love.update(dt)
    loci.update(dt)

    -- Movement controls (WASD / Arrows)
    local dx, dy = 0, 0
    if love.keyboard.isDown("w") or love.keyboard.isDown("up") then dy = -1 end
    if love.keyboard.isDown("s") or love.keyboard.isDown("down") then dy = 1 end
    if love.keyboard.isDown("a") or love.keyboard.isDown("left") then dx = -1 end
    if love.keyboard.isDown("d") or love.keyboard.isDown("right") then dx = 1 end

    if dx ~= 0 or dy ~= 0 then
        loci.send_move(dx, dy)
    end
end

function love.mousepressed(x, y, button)
    if button == 1 then
        -- Cast ability 1 towards mouse cursor
        loci.send_action_at_position(1, x, y)
    end
end

function love.draw()
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("Status: " .. status_text, 10, 10)
    love.graphics.print("Controls: WASD to move, Left-Click to cast ability", 10, 30)

    local entities = loci.get_entities()
    for _, entity in ipairs(entities) do
        if entity:is_local_player() then
            love.graphics.setColor(0.2, 0.6, 1.0) -- Blue for local player
        else
            love.graphics.setColor(0.9, 0.3, 0.3) -- Red for other entities
        end
        love.graphics.circle("fill", entity.x, entity.y, 16)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(entity.name or ("ID: " .. entity.id), entity.x - 20, entity.y - 30)
    end
end

function love.quit()
    loci.disconnect("Game closing")
end
