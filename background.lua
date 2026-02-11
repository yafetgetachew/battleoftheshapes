-- background.lua
-- Parallax background system with moon, stars, mountains, and clouds

local Physics = require("physics")

local Background = {}

-- Configuration
local GAME_WIDTH = 1280
local GAME_HEIGHT = 720
local GROUND_Y = Physics.GROUND_Y

-- Color palette (moonlit night)
local COLORS = {
    skyTop = {0.04, 0.04, 0.12},       -- Deep navy
    skyBottom = {0.10, 0.08, 0.18},    -- Purple-navy gradient
    moon = {0.95, 0.92, 0.75},         -- Pale yellow-white
    moonGlow = {0.95, 0.92, 0.75, 0.15},
    starBase = {1, 1, 1},
    mountainFar = {0.12, 0.10, 0.18},  -- Dark purple-grey (furthest)
    mountainMid = {0.08, 0.06, 0.14},  -- Darker
    mountainNear = {0.05, 0.04, 0.10}, -- Darkest silhouette (closest)
    cloudFar = {0.4, 0.45, 0.55, 0.15},
    cloudNear = {0.35, 0.40, 0.50, 0.25},
}

-- Background elements
local stars = {}
local mountains = {}  -- 3 layers of mountain silhouettes
local clouds = {}     -- 2 layers of clouds
local moonX, moonY = 200, 100
local moonRadius = 55

-- Parallax factors (lower = moves slower = feels further)
local PARALLAX = {
    stars = 0.02,
    moon = 0.03,
    mountainFar = 0.05,
    mountainMid = 0.10,
    mountainNear = 0.18,
    cloudFar = 0.08,
    cloudNear = 0.15,
}

-- Cloud drift speeds
local CLOUD_SPEEDS = {
    far = 8,   -- pixels per second
    near = 15,
}

-- Generate jagged mountain points for a layer
local function generateMountainLayer(baseY, peakHeight, numPeaks, jaggedness)
    local points = {}
    local segmentWidth = (GAME_WIDTH + 400) / numPeaks  -- Extra width for parallax
    
    -- Start from left edge
    table.insert(points, -200)
    table.insert(points, GROUND_Y)
    
    for i = 0, numPeaks do
        local x = -200 + i * segmentWidth
        local peakOffset = (math.random() - 0.5) * segmentWidth * 0.4
        local height = peakHeight * (0.6 + math.random() * 0.4)
        
        -- Add intermediate jagged points
        if i > 0 then
            local midX = x - segmentWidth * 0.5 + (math.random() - 0.5) * jaggedness
            local midY = baseY - height * (0.3 + math.random() * 0.4)
            table.insert(points, midX)
            table.insert(points, midY)
        end
        
        -- Peak
        table.insert(points, x + peakOffset)
        table.insert(points, baseY - height)
    end
    
    -- End at right edge
    table.insert(points, GAME_WIDTH + 200)
    table.insert(points, GROUND_Y)
    
    return points
end

-- Generate a cloud as a smooth polygon outline (puffy cloud shape)
local function generateCloud(layer)
    local cloud = {
        x = math.random(-200, GAME_WIDTH + 200),
        y = math.random(60, 280),
        layer = layer,
        points = {}  -- polygon points for the cloud shape
    }

    -- Cloud dimensions
    local width = 80 + math.random() * 60   -- 80-140 pixels wide
    local height = 25 + math.random() * 20  -- 25-45 pixels tall

    -- Generate puffy top with bumps, flat bottom
    local numBumps = math.random(3, 5)
    local pts = {}

    -- Start from bottom-left, go clockwise
    -- Bottom edge (flat)
    table.insert(pts, -width/2)
    table.insert(pts, height * 0.3)

    -- Left side curve up
    table.insert(pts, -width/2 - 5)
    table.insert(pts, 0)

    -- Top bumps (the puffy part)
    for i = 0, numBumps do
        local t = i / numBumps
        local x = -width/2 + t * width
        -- Vary the height of each bump
        local bumpHeight = height * (0.6 + math.random() * 0.4)
        local y = -bumpHeight
        -- Add slight horizontal variation
        x = x + (math.random() - 0.5) * 10
        table.insert(pts, x)
        table.insert(pts, y)

        -- Add intermediate point between bumps for roundness
        if i < numBumps then
            local midX = x + (width / numBumps) * 0.5
            local midY = -height * (0.3 + math.random() * 0.3)
            table.insert(pts, midX)
            table.insert(pts, midY)
        end
    end

    -- Right side curve down
    table.insert(pts, width/2 + 5)
    table.insert(pts, 0)

    -- Bottom-right
    table.insert(pts, width/2)
    table.insert(pts, height * 0.3)

    cloud.points = pts
    return cloud
end

-- Draw a single cloud using its polygon
local function drawCloud(cloud, cloudX, color)
    local pts = cloud.points
    if #pts < 6 then return end

    -- Translate points to world position
    local translatedPts = {}
    for i = 1, #pts, 2 do
        table.insert(translatedPts, pts[i] + cloudX)
        table.insert(translatedPts, pts[i + 1] + cloud.y)
    end

    -- Draw filled polygon
    love.graphics.setColor(color)
    local ok, triangles = pcall(love.math.triangulate, translatedPts)
    if ok and triangles then
        for _, tri in ipairs(triangles) do
            love.graphics.polygon("fill", tri)
        end
    end
end

function Background.init()
    math.randomseed(os.time())
    
    -- Generate stars (more than before, with varying sizes)
    for i = 1, 120 do
        stars[i] = {
            x = math.random() * (GAME_WIDTH + 100) - 50,
            y = math.random() * 350,
            radius = math.random() * 1.5 + 0.3,
            brightness = math.random() * 0.6 + 0.2,
            twinkleSpeed = math.random() * 2 + 0.5,
            twinklePhase = math.random() * math.pi * 2,
        }
    end
    
    -- Generate 3 mountain layers (far to near)
    mountains = {
        generateMountainLayer(GROUND_Y - 60, 180, 6, 30),   -- Far mountains
        generateMountainLayer(GROUND_Y - 40, 140, 8, 25),   -- Mid mountains
        generateMountainLayer(GROUND_Y - 20, 100, 10, 20),  -- Near mountains
    }
    
    -- Generate clouds (2 layers)
    for i = 1, 5 do
        table.insert(clouds, generateCloud("far"))
    end
    for i = 1, 4 do
        table.insert(clouds, generateCloud("near"))
    end
end

function Background.update(dt)
    -- Animate clouds drifting
    for _, cloud in ipairs(clouds) do
        local speed = cloud.layer == "far" and CLOUD_SPEEDS.far or CLOUD_SPEEDS.near
        cloud.x = cloud.x + speed * dt
        
        -- Wrap around when cloud goes off-screen
        if cloud.x > GAME_WIDTH + 300 then
            cloud.x = -300
            cloud.y = math.random(60, 280)
        end
    end
end

function Background.draw(W, H, cameraOffsetX)
    cameraOffsetX = cameraOffsetX or 0
    local time = love.timer.getTime()

    -- ── Sky gradient ──
    for y = 0, GROUND_Y, 4 do
        local t = y / GROUND_Y
        love.graphics.setColor(
            COLORS.skyTop[1] + (COLORS.skyBottom[1] - COLORS.skyTop[1]) * t,
            COLORS.skyTop[2] + (COLORS.skyBottom[2] - COLORS.skyTop[2]) * t,
            COLORS.skyTop[3] + (COLORS.skyBottom[3] - COLORS.skyTop[3]) * t
        )
        love.graphics.rectangle("fill", 0, y, W, 4)
    end

    -- ── Moon with glow ──
    local moonParallaxX = moonX - cameraOffsetX * PARALLAX.moon

    -- Outer glow layers
    for i = 3, 1, -1 do
        local glowRadius = moonRadius + i * 25
        local alpha = 0.08 / i
        love.graphics.setColor(COLORS.moon[1], COLORS.moon[2], COLORS.moon[3], alpha)
        love.graphics.circle("fill", moonParallaxX, moonY, glowRadius)
    end

    -- Moon surface
    love.graphics.setColor(COLORS.moon[1], COLORS.moon[2], COLORS.moon[3], 0.95)
    love.graphics.circle("fill", moonParallaxX, moonY, moonRadius)

    -- Subtle crater shadows
    love.graphics.setColor(0.85, 0.82, 0.70, 0.3)
    love.graphics.circle("fill", moonParallaxX - 15, moonY - 10, 12)
    love.graphics.circle("fill", moonParallaxX + 20, moonY + 5, 8)
    love.graphics.circle("fill", moonParallaxX - 5, moonY + 18, 6)

    -- ── Stars with twinkling ──
    for _, star in ipairs(stars) do
        local starX = star.x - cameraOffsetX * PARALLAX.stars
        local twinkle = star.brightness + math.sin(time * star.twinkleSpeed + star.twinklePhase) * 0.15
        love.graphics.setColor(COLORS.starBase[1], COLORS.starBase[2], COLORS.starBase[3], twinkle)
        love.graphics.circle("fill", starX, star.y, star.radius)
    end

    -- ── Far clouds (behind mountains) ──
    for _, cloud in ipairs(clouds) do
        if cloud.layer == "far" then
            local cloudX = cloud.x - cameraOffsetX * PARALLAX.cloudFar
            drawCloud(cloud, cloudX, COLORS.cloudFar)
        end
    end

    -- ── Mountain layers (far to near) ──
    local mountainColors = {COLORS.mountainFar, COLORS.mountainMid, COLORS.mountainNear}
    local mountainParallax = {PARALLAX.mountainFar, PARALLAX.mountainMid, PARALLAX.mountainNear}

    for layer = 1, 3 do
        local pts = mountains[layer]
        local offsetX = -cameraOffsetX * mountainParallax[layer]

        -- Offset all points
        local translatedPts = {}
        for i = 1, #pts, 2 do
            table.insert(translatedPts, pts[i] + offsetX)
            table.insert(translatedPts, pts[i + 1])
        end

        love.graphics.setColor(mountainColors[layer])
        if #translatedPts >= 6 then
            love.graphics.polygon("fill", translatedPts)
        end
    end

    -- ── Near clouds (in front of mountains, subtle) ──
    for _, cloud in ipairs(clouds) do
        if cloud.layer == "near" then
            local cloudX = cloud.x - cameraOffsetX * PARALLAX.cloudNear
            drawCloud(cloud, cloudX, COLORS.cloudNear)
        end
    end
end

-- Calculate parallax offset based on average player position
function Background.getParallaxOffset(players, W)
    if not players or #players == 0 then
        return 0
    end

    local sumX = 0
    local count = 0
    for _, p in ipairs(players) do
        if p.life and p.life > 0 then
            sumX = sumX + p.x
            count = count + 1
        end
    end

    if count == 0 then
        return 0
    end

    local avgX = sumX / count
    local centerX = W / 2

    -- Return offset from center (how far players are from center on average)
    return avgX - centerX
end

return Background

