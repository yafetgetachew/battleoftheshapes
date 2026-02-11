-- background.lua
-- Parallax background system with moon, stars, mountains, and clouds
-- Plus ambient particles, reactive effects, and foreground silhouettes

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
    dustMote = {0.9, 0.85, 0.7, 0.3},
    fallingStar = {1, 1, 0.9},
    fog = {0.3, 0.35, 0.45, 0.12},
    foreground = {0.02, 0.02, 0.05},   -- Very dark silhouette
}

-- Background elements
local stars = {}
local mountains = {}  -- 3 layers of mountain silhouettes
local clouds = {}     -- 2 layers of clouds
local moonX, moonY = 200, 100
local moonRadius = 55

-- Ambient particles
local dustMotes = {}
local fallingStars = {}
local fogLayers = {}

-- Foreground silhouettes
local foregroundElements = {}

-- Reactive state
local lightningFlashTimer = 0    -- Brightens clouds on lightning
local moonPulseTimer = 0         -- Moon glow pulse on match start
local moonPulseIntensity = 0

-- Parallax factors (lower = moves slower = feels further)
local PARALLAX = {
    stars = 0.02,
    moon = 0.03,
    mountainFar = 0.05,
    mountainMid = 0.10,
    mountainNear = 0.18,
    cloudFar = 0.08,
    cloudNear = 0.15,
    foreground = 0.35,  -- Foreground moves faster (closer)
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

-- Generate a dust mote particle
local function generateDustMote()
    return {
        x = math.random() * GAME_WIDTH,
        y = math.random() * (GROUND_Y - 100) + 50,
        size = math.random() * 2 + 1,
        alpha = math.random() * 0.2 + 0.1,
        driftX = (math.random() - 0.5) * 15,  -- Slow horizontal drift
        driftY = (math.random() - 0.5) * 8,   -- Slow vertical drift
        wobblePhase = math.random() * math.pi * 2,
        wobbleSpeed = math.random() * 1.5 + 0.5,
    }
end

-- Generate a foreground silhouette element
local function generateForegroundElement(side)
    local element = {
        side = side,  -- "left" or "right"
        type = math.random(1, 3),  -- 1=tree branch, 2=dead tree, 3=ruin pillar
        x = side == "left" and -50 or GAME_WIDTH + 50,
        baseY = GROUND_Y,
    }
    return element
end

-- Draw a foreground silhouette
local function drawForegroundElement(elem, offsetX)
    local x = elem.x - offsetX * PARALLAX.foreground
    local y = elem.baseY

    love.graphics.setColor(COLORS.foreground)

    if elem.type == 1 then
        -- Tree branch reaching in from side
        local dir = elem.side == "left" and 1 or -1
        love.graphics.setLineWidth(4)
        -- Main branch
        love.graphics.line(x, y - 200, x + dir * 80, y - 280)
        love.graphics.line(x + dir * 80, y - 280, x + dir * 140, y - 260)
        -- Sub-branches
        love.graphics.setLineWidth(2)
        love.graphics.line(x + dir * 60, y - 270, x + dir * 90, y - 320)
        love.graphics.line(x + dir * 100, y - 265, x + dir * 130, y - 300)
        love.graphics.line(x + dir * 120, y - 262, x + dir * 160, y - 240)
    elseif elem.type == 2 then
        -- Dead tree silhouette
        local dir = elem.side == "left" and 1 or -1
        -- Trunk
        love.graphics.polygon("fill",
            x, y,
            x + dir * 15, y,
            x + dir * 12, y - 180,
            x + dir * 3, y - 180
        )
        -- Branches
        love.graphics.setLineWidth(3)
        love.graphics.line(x + dir * 8, y - 140, x + dir * 50, y - 200)
        love.graphics.line(x + dir * 10, y - 100, x + dir * 60, y - 130)
        love.graphics.setLineWidth(2)
        love.graphics.line(x + dir * 40, y - 190, x + dir * 70, y - 220)
    else
        -- Ruined pillar/column
        local dir = elem.side == "left" and 1 or -1
        love.graphics.polygon("fill",
            x, y,
            x + dir * 25, y,
            x + dir * 22, y - 120,
            x + dir * 28, y - 130,
            x + dir * 18, y - 140,
            x + dir * 8, y - 135,
            x + dir * 3, y - 120
        )
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

    -- Generate dust motes
    for i = 1, 25 do
        table.insert(dustMotes, generateDustMote())
    end

    -- Generate fog layers (horizontal bands near ground)
    for i = 1, 3 do
        table.insert(fogLayers, {
            y = GROUND_Y - 30 - i * 25,
            height = 40 + math.random() * 20,
            alpha = 0.08 + math.random() * 0.06,
            driftPhase = math.random() * math.pi * 2,
        })
    end

    -- Generate foreground silhouettes
    table.insert(foregroundElements, generateForegroundElement("left"))
    table.insert(foregroundElements, generateForegroundElement("right"))
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

    -- Update dust motes (gentle drifting)
    for _, mote in ipairs(dustMotes) do
        local time = love.timer.getTime()
        local wobble = math.sin(time * mote.wobbleSpeed + mote.wobblePhase) * 5
        mote.x = mote.x + (mote.driftX + wobble * 0.5) * dt
        mote.y = mote.y + mote.driftY * dt

        -- Wrap around
        if mote.x < -10 then mote.x = GAME_WIDTH + 10 end
        if mote.x > GAME_WIDTH + 10 then mote.x = -10 end
        if mote.y < 30 then mote.y = GROUND_Y - 100 end
        if mote.y > GROUND_Y - 50 then mote.y = 50 end
    end

    -- Update falling stars
    for i = #fallingStars, 1, -1 do
        local star = fallingStars[i]
        star.x = star.x + star.vx * dt
        star.y = star.y + star.vy * dt
        star.age = star.age + dt
        star.trail = star.trail or {}
        -- Add trail point
        table.insert(star.trail, 1, {x = star.x, y = star.y})
        if #star.trail > 8 then table.remove(star.trail) end
        -- Remove when off-screen or too old
        if star.age > star.life or star.y > GROUND_Y or star.x > GAME_WIDTH + 50 then
            table.remove(fallingStars, i)
        end
    end

    -- Occasionally spawn a falling star (rare)
    if math.random() < 0.001 then  -- ~0.1% chance per frame
        table.insert(fallingStars, {
            x = math.random(100, GAME_WIDTH - 100),
            y = math.random(20, 150),
            vx = math.random(200, 400),
            vy = math.random(150, 300),
            age = 0,
            life = math.random() * 0.5 + 0.3,
            brightness = math.random() * 0.3 + 0.7,
            trail = {},
        })
    end

    -- Decay reactive effects
    if lightningFlashTimer > 0 then
        lightningFlashTimer = lightningFlashTimer - dt * 3  -- Fast decay
    end
    if moonPulseTimer > 0 then
        moonPulseTimer = moonPulseTimer - dt
        moonPulseIntensity = moonPulseTimer / 2  -- Fade over 2 seconds
    end
end

-- Trigger lightning flash effect (call from main when lightning strikes)
function Background.onLightningStrike()
    lightningFlashTimer = 1.0
end

-- Trigger moon pulse effect (call from main on match start)
function Background.onMatchStart()
    moonPulseTimer = 2.0
    moonPulseIntensity = 1.0
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

    -- ── Moon with glow (reactive: pulses on match start) ──
    local moonParallaxX = moonX - cameraOffsetX * PARALLAX.moon
    local moonGlowBoost = moonPulseIntensity * 0.15  -- Extra glow on match start

    -- Outer glow layers
    for i = 3, 1, -1 do
        local glowRadius = moonRadius + i * 25 + moonPulseIntensity * 10
        local alpha = (0.08 + moonGlowBoost) / i
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

    -- ── Falling stars (shooting stars) ──
    for _, fstar in ipairs(fallingStars) do
        local alpha = fstar.brightness * (1 - fstar.age / fstar.life)
        -- Draw trail
        for i, pt in ipairs(fstar.trail) do
            local trailAlpha = alpha * (1 - i / #fstar.trail) * 0.6
            local trailSize = 2 * (1 - i / #fstar.trail)
            love.graphics.setColor(COLORS.fallingStar[1], COLORS.fallingStar[2], COLORS.fallingStar[3], trailAlpha)
            love.graphics.circle("fill", pt.x, pt.y, trailSize)
        end
        -- Draw head
        love.graphics.setColor(COLORS.fallingStar[1], COLORS.fallingStar[2], COLORS.fallingStar[3], alpha)
        love.graphics.circle("fill", fstar.x, fstar.y, 2.5)
    end

    -- ── Far clouds (behind mountains, reactive: brighten on lightning) ──
    local cloudBrighten = math.max(0, lightningFlashTimer) * 0.3
    for _, cloud in ipairs(clouds) do
        if cloud.layer == "far" then
            local cloudX = cloud.x - cameraOffsetX * PARALLAX.cloudFar
            local color = {
                COLORS.cloudFar[1] + cloudBrighten,
                COLORS.cloudFar[2] + cloudBrighten,
                COLORS.cloudFar[3] + cloudBrighten,
                COLORS.cloudFar[4]
            }
            drawCloud(cloud, cloudX, color)
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

    -- ── Near clouds (in front of mountains, reactive: brighten on lightning) ──
    for _, cloud in ipairs(clouds) do
        if cloud.layer == "near" then
            local cloudX = cloud.x - cameraOffsetX * PARALLAX.cloudNear
            local color = {
                COLORS.cloudNear[1] + cloudBrighten,
                COLORS.cloudNear[2] + cloudBrighten,
                COLORS.cloudNear[3] + cloudBrighten,
                COLORS.cloudNear[4]
            }
            drawCloud(cloud, cloudX, color)
        end
    end

    -- ── Dust motes (floating particles in mid-air) ──
    for _, mote in ipairs(dustMotes) do
        local wobble = math.sin(time * mote.wobbleSpeed + mote.wobblePhase)
        local alpha = mote.alpha * (0.7 + 0.3 * wobble)
        love.graphics.setColor(COLORS.dustMote[1], COLORS.dustMote[2], COLORS.dustMote[3], alpha)
        love.graphics.circle("fill", mote.x, mote.y, mote.size)
    end

    -- ── Fog layers near ground ──
    for _, fog in ipairs(fogLayers) do
        local drift = math.sin(time * 0.3 + fog.driftPhase) * 30
        local alpha = fog.alpha * (0.8 + 0.2 * math.sin(time * 0.5 + fog.driftPhase))
        love.graphics.setColor(COLORS.fog[1], COLORS.fog[2], COLORS.fog[3], alpha)
        -- Draw as a soft horizontal band
        love.graphics.rectangle("fill", -50 + drift, fog.y, W + 100, fog.height)
    end
end

-- Draw foreground silhouettes (call after game world, before HUD)
function Background.drawForeground(W, H, cameraOffsetX)
    cameraOffsetX = cameraOffsetX or 0
    for _, elem in ipairs(foregroundElements) do
        drawForegroundElement(elem, cameraOffsetX)
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

