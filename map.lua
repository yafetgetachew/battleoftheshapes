-- map.lua
-- Defines the map layout with animated platforms

local Map = {}

-- Animation settings
Map.ANIMATION_SPEED = 0.5       -- How fast platforms oscillate (radians per second)
Map.ANIMATION_AMPLITUDE = 40    -- Max horizontal displacement in pixels

-- Animation time (accumulates in update)
local animTime = 0

-- Base platform positions (center x, center y, width, height)
-- Each platform has an animation phase offset and direction
local platformDefs = {
    -- Left elevated platform (moves right first)
    {baseX = 300, y = 450, w = 200, h = 20, phase = 0, dir = 1},
    -- Right elevated platform (moves left first, opposite of left)
    {baseX = 980, y = 450, w = 200, h = 20, phase = math.pi, dir = 1},
    -- Center high platform (moves right first, different phase)
    {baseX = 640, y = 300, w = 300, h = 20, phase = math.pi / 2, dir = 1},
    -- Lower center platform (stationary - no amplitude)
    {baseX = 640, y = 550, w = 150, h = 20, phase = 0, dir = 0},
}

-- Runtime platform positions (these get updated each frame)
Map.platforms = {}

-- Initialize platforms at base positions
local function initPlatforms()
    for i, def in ipairs(platformDefs) do
        Map.platforms[i] = {
            x = def.baseX,
            y = def.y,
            w = def.w,
            h = def.h
        }
    end
end
initPlatforms()

-- Reset animation state
function Map.reset()
    animTime = 0
    initPlatforms()
end

-- Update platform positions
function Map.update(dt)
    animTime = animTime + dt

    for i, def in ipairs(platformDefs) do
        if def.dir ~= 0 then
            -- Calculate horizontal offset using sine wave
            local offset = math.sin(animTime * Map.ANIMATION_SPEED + def.phase) * Map.ANIMATION_AMPLITUDE * def.dir
            Map.platforms[i].x = def.baseX + offset
        end
    end
end

function Map.draw()
    love.graphics.setColor(0.4, 0.3, 0.5) -- Darkish purple/slate for platforms
    for _, plat in ipairs(Map.platforms) do
        -- Draw rectangle (mode, x, y, w, h)
        -- Since we defined x,y as center, we draw at x - w/2, y - h/2
        love.graphics.rectangle("fill", plat.x - plat.w/2, plat.y - plat.h/2, plat.w, plat.h)

        -- Add a lighter border top look
        love.graphics.setColor(0.6, 0.5, 0.7)
        love.graphics.rectangle("fill", plat.x - plat.w/2, plat.y - plat.h/2, plat.w, 4)

        -- Reset color for next
        love.graphics.setColor(0.4, 0.3, 0.5)
    end
    love.graphics.setColor(1, 1, 1) -- Reset to white
end

return Map
