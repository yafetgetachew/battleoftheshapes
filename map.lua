-- map.lua
-- Defines the static map layout (platforms)

local Map = {}

-- Define platforms as {x, y, width, height}
-- Coordinates are center-based or top-left? 
-- Let's use CENTER-based x, y to match shapes, but width/height are full dimensions.
-- Wait, Love2D rectangles are usually top-left.
-- Let's stick to {x = center_x, y = center_y, w = width, h = height} to match player logic if possible,
-- OR just use standard top-left for static level geometry.
-- Players use center x,y.
-- Let's use Top-Left for easy drawing, but convert during collision if needed.
-- Actually, let's keep it consistent: Center X, Center Y.

Map.platforms = {
    -- Left elevated platform
    {x = 300, y = 450, w = 200, h = 20},
    -- Right elevated platform
    {x = 980, y = 450, w = 200, h = 20},
    -- Center high platform
    {x = 640, y = 300, w = 300, h = 20},
    -- Lower center platform
    {x = 640, y = 550, w = 150, h = 20},
}

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
